# ===== GLOBALS =====
$global:sshServer      = "server1.example.com" #Must be able to run /nfs/site/gen/adm/linuxset/hardware/firmware/support_scripts/redfish_mgmt_utility/redfish_mgmt.py 
$global:cobblerServer      = "server1.example.com"


# ==== login servers =====
$global:sshServers = @(
   "server1.example.comserver1.example.com"
)

$global:ResolutionOrder = @('AcCycle' ,'PowerOn', 'CobblerCheck', 'BmcReset','PxeReset1')
$global:ResolutionOrderRebuild  = @('PxeReset1')
$global:linuxUser = ($env:USERNAME -replace "^ad_", "")

$global:shutdown       = $false

# Ensure-TampermonkeyInstalled -Browsers Edge    # Edge only
function Ensure-TampermonkeyInstalled {
    [CmdletBinding()]
    param(
        [ValidateSet('Edge','Chrome')]
        [string[]] $Browsers = @('Edge','Chrome'),
        [switch]   $RestartBrowsers
    )

    # Per-browser IDs + update URLs
    $ext = @{
        Edge   = @{ Id = 'iikmkjmpaadaobahmlepeloendndfphd'; Url = 'https://edge.microsoft.com/extensionwebstorebase/v1/crx' }
        Chrome = @{ Id = 'dhdgffkkebhmkfjojejmpbldmpobfkfo'; Url = 'https://clients2.google.com/service/update2/crx' }
    }

    $changed = $false

    foreach ($b in $Browsers) {

        switch ($b) {
            'Edge' {
                $baseKey        = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
                $recommendedKey = Join-Path $baseKey 'Recommended'   # for ControlDefaultStateOfAllowExtensionFromOtherStoresSettingEnabled
            }
            'Chrome' {
                $baseKey        = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
                $recommendedKey = $null
            }
        }

        # Ensure base keys
        if (-not (Test-Path $baseKey)) { New-Item -Path $baseKey -Force | Out-Null }

        # --- CLEANUP wrong/legacy entries ---
        foreach ($bad in @('AllowExtensionsFromOtherStores','ExtensionsEnabled')) {
            Remove-ItemProperty -Path $baseKey -Name $bad -ErrorAction SilentlyContinue
        }
        $legacySubkey = Join-Path $baseKey 'ExtensionSettings'
        if (Test-Path $legacySubkey) { Remove-Item $legacySubkey -Recurse -Force -ErrorAction SilentlyContinue }

        # --- Write a valid ExtensionSettings VALUE (single JSON string) ---
        $id  = $ext[$b].Id
        $url = $ext[$b].Url
        $extJson = @{ $id = @{ installation_mode = 'force_installed'; update_url = $url } } | ConvertTo-Json -Compress
        Set-ItemProperty -Path $baseKey -Name 'ExtensionSettings' -Type String -Value $extJson
        Write-Host "[$b] ExtensionSettings set → force_installed, update_url=$url"
        $changed = $true

        # --- Ensure ExtensionInstallForcelist has the entry (no dupes) ---
        $forceKey = Join-Path $baseKey 'ExtensionInstallForcelist'
        if (-not (Test-Path $forceKey)) { New-Item -Path $forceKey -Force | Out-Null }
        $props = Get-ItemProperty -Path $forceKey -ErrorAction SilentlyContinue
        $existing = @{}
        if ($props) {
            $props.PSObject.Properties |
                Where-Object { $_.MemberType -eq 'NoteProperty' } |
                ForEach-Object { $existing[[string]$_.Value] = $true }
        }
        $pair = "$id;$url"

        # robust next-index calc
        $next = 1
        if ($props) {
            $indices = $props.PSObject.Properties |
                       Where-Object { $_.MemberType -eq 'NoteProperty' -and $_.Name -match '^\d+$' } |
                       ForEach-Object { [int]$_.Name }
            if ($indices -and $indices.Count -gt 0) {
                $max = ($indices | Measure-Object -Maximum).Maximum
                if ($null -ne $max) { $next = [int]$max + 1 }
            }
        }

        if (-not $existing.ContainsKey($pair)) {
            New-ItemProperty -Path $forceKey -Name $next -PropertyType String -Value $pair -Force | Out-Null
            Write-Host "[$b] Forcelist added @$next → $pair"
            $changed = $true
        } else {
            Write-Host "[$b] Forcelist already contains → $pair"
        }

        # --- Edge only: set the proper 'Allow extensions from other stores' policy (Recommended path) ---
        if ($b -eq 'Edge') {
            if (-not (Test-Path $recommendedKey)) { New-Item -Path $recommendedKey -Force | Out-Null }
            New-ItemProperty -Path $recommendedKey `
                -Name 'ControlDefaultStateOfAllowExtensionFromOtherStoresSettingEnabled' `
                -PropertyType DWord -Value 1 -Force | Out-Null
            Write-Host "[Edge] Recommended policy set: ControlDefaultStateOfAllowExtensionFromOtherStoresSettingEnabled=1"
            $changed = $true
        }
    }

    if ($changed) {
        Write-Host "Refreshing policies…"
        gpupdate /target:computer /force | Out-Null
        if ($RestartBrowsers) {
            Get-Process msedge, chrome -ErrorAction SilentlyContinue | Stop-Process -Force
            Write-Host "Browsers closed."
        } else {
            Write-Host "edge://policy and edge://extensions."
        }
    } else {
        Write-Host "No changes required."
    }
    
}

function Show-EdgeDevModeInstructions {
    [CmdletBinding()]
    param(
        # Path to the static HTML page you saved (default: Enable-TM-DevMode.html next to this script)
        [string]$HtmlFile = $( if ($PSScriptRoot) { Join-Path $PSScriptRoot 'src\Enable-TM-DevMode.html' } else { Join-Path (Get-Location) 'src\Enable-TM-DevMode.html' } ),

        # Browser executable
        [string]$BrowserExe = 'msedge.exe'
    )

    if (-not (Test-Path -LiteralPath $HtmlFile)) {
        throw "HTML file not found: $HtmlFile"
    }

    Write-Host ""
    Write-Host "Edge will open with instructions to:" -ForegroundColor Yellow
    Write-Host "  • Enable Developer mode" 
    Write-Host "  • Then enable 'Allow access to file URLs' on the Tampermonkey details page" 
    Write-Host ""
    $null = Read-Host "Press ENTER to open the instructions page in Edge"

    # Convert to a proper file:// URI so Edge opens it reliably
    $absPath = (Resolve-Path -LiteralPath $HtmlFile).Path
    $uri     = ([System.Uri]$absPath).AbsoluteUri

    $opened = $false
    try { Start-Process -FilePath $BrowserExe -ArgumentList $uri; $opened = $true } catch {}
    if (-not $opened) {
        # Fallback via protocol handler
        try { Start-Process -FilePath "cmd.exe" -ArgumentList "/c start microsoft-edge:$uri"; $opened = $true } catch {}
    }

    if ($opened) {
        Write-Host "Opened Edge with instructions" -ForegroundColor Cyan
    } else {
        Write-Warning "Could not launch Edge automatically. Open this URL manually:`n$uri"
    }

    Write-Host ""
    $null = Read-Host "When finished, press ENTER here to continue"
    return $true
}

function Prompt-InstallCMDBUserScript {
    [CmdletBinding()]
    param(
        # Default: CMDB.user.js next to this script
        [string]$ScriptFile = $( if ($PSScriptRoot) { Join-Path $PSScriptRoot 'src\CMDB.user.js' } else { Join-Path (Get-Location) 'src\CMDB.user.js' } ),
        # Browser executable
        [string]$BrowserExe = 'msedge.exe'
    )

    if (-not (Test-Path -LiteralPath $ScriptFile)) {
        throw "User script not found: $ScriptFile"
    }

    Write-Host ""
    Write-Host "We're going to open Edge to install the CMDB Tampermonkey script." -ForegroundColor Yellow
    Write-Host "Make sure the following are already enabled in Edge:" 
    Write-Host "  • Developer mode (edge://extensions/)"
    Write-Host "  • Tampermonkey → 'Allow access to file URLs' (edge://extensions/?id=iikmkjmpaadaobahmlepeloendndfphd)"
    Write-Host ""
    $null = Read-Host "Press ENTER to open the CMDB.user.js install page in Edge"

    $absPath = (Resolve-Path -LiteralPath $ScriptFile).Path

    # Open directly — you said this works: Start-Process "msedge.exe" "CMDB.user.js"
    $opened = $false
    try {
        Start-Process -FilePath $BrowserExe -ArgumentList $absPath
        $opened = $true
        Write-Host "Opened Edge → $absPath" -ForegroundColor Cyan
    } catch {
        # Fallback to file:// URI if needed
        $fileUri = ([System.Uri]$absPath).AbsoluteUri
        try {
            Start-Process -FilePath $BrowserExe -ArgumentList $fileUri
            $opened = $true
            Write-Host "Opened Edge → $fileUri" -ForegroundColor Cyan
        } catch {
            # Last resort: protocol handler
            Start-Process "cmd.exe" "/c start microsoft-edge:$fileUri"
            Write-Host "Tried protocol handler → microsoft-edge:$fileUri" -ForegroundColor Cyan
        }
    }

    Write-Host ""
    $null = Read-Host "After you click 'Install' in Tampermonkey, press ENTER here to continue"
    return $true
}

function Stop-SshAtStartup {
  param([switch]$Aggressive)

  if ($Aggressive) {
    Get-Process ssh,plink -ErrorAction SilentlyContinue | ForEach-Object {
      try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
  } else {
    try { $procs = Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" } catch { $procs = Get-WmiObject Win32_Process -Filter "Name='ssh.exe'" }
    $procs | Where-Object { $_.CommandLine -match 'ipmitool.+sol activate' } | ForEach-Object {
      try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
  }

  $dir = Join-Path $PSScriptRoot 'sol-logs'
  Get-ChildItem "$dir\*.pid" -ErrorAction SilentlyContinue | ForEach-Object {
    $procId = (Get-Content $_ -ErrorAction SilentlyContinue) -as [int]
    if ($procId) { try { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue } catch {} }
    Remove-Item $_ -Force -ErrorAction SilentlyContinue
  }
}
# ===== Old host-file cleanup =====
function Remove-OldHostFiles {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [int]$Days = 5,
        [string]$Dir = (Join-Path $PSScriptRoot "hosts"),
        [string[]]$Include = @('*.psd1'),
        [switch]$Recurse
    )
    Write-Host "`nRemoving host records older than $Days days`n" -ForegroundColor Cyan
    Write-Host "[CLEANUP] Starting host-file cleanup…"
    Write-Host "[CLEANUP] Directory: $Dir"
    Write-Host "[CLEANUP] Age threshold: $Days day(s)"
    Write-Host "[CLEANUP] Include pattern(s): $($Include -join ', ')"
    Write-Host "[CLEANUP] Recurse: $($Recurse.IsPresent)"

    if (-not (Test-Path $Dir)) {
        Write-Host "[CLEANUP] Hosts dir not found → nothing to do."
        return @{ deleted=0; skipped=0; total=0; dir=$Dir; cutoff=$null; errors=@() }
    }

    $cutoff = (Get-Date).AddDays(-$Days)
    Write-Host "[CLEANUP] Cutoff timestamp: $($cutoff.ToString('s'))"

    # Gather candidates
    $items = Get-ChildItem -Path $Dir -File -Include $Include -Recurse:$Recurse -ErrorAction SilentlyContinue
    $targets = $items | Where-Object { $_.LastWriteTime -lt $cutoff }

    Write-Host "[CLEANUP] Found $($targets.Count) candidate(s) to remove."

    $deleted = 0
    $skipped = 0
    $errors  = @()

    foreach ($f in $targets) {
        $ageDays = [int]([Math]::Floor(((Get-Date) - $f.LastWriteTime).TotalDays))
        Write-Host "[CLEANUP] Candidate: $($f.Name)  Age=${ageDays}d  Path=$($f.FullName)"
        if ($PSCmdlet.ShouldProcess($f.FullName, "Remove old host file")) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force
                $deleted++
                Write-Host "[CLEANUP] Deleted: $($f.FullName)"
            } catch {
                $msg = "$($f.FullName): $($_.Exception.Message)"
                $errors += $msg
                Write-Host "[CLEANUP][FAIL] $msg"
            }
        } else {
            $skipped++
            Write-Host "[CLEANUP] Skipped by operator choice: $($f.FullName)"
        }
    }

    Write-Host "[CLEANUP] Completed. Deleted=$deleted  Skipped=$skipped  TotalCandidates=$($targets.Count)"
    return @{
        deleted = $deleted
        skipped = $skipped
        total   = $targets.Count
        dir     = $Dir
        cutoff  = $cutoff.ToString('s')
        errors  = $errors
    }
}
# ----- PLAN INITIALIZER (interactive) -----
function Initialize-ResolutionPlan {
    param(
        # Default ordered list (you can keep or optionally reorder interactively)
        [string[]]$Steps = @('PowerOn','AcCycle','PxeReset1','CobblerCheck','Reboot','PxeReset2'),
        # If you ever want to drive non-interactively, you can pass -NonInteractive and -Skip
        [switch]$NonInteractive = $false,
        [hashtable]$Skip = @{}
    )
    Write-Host "`nConfiguring resolution plan`n" -ForegroundColor Cyan
    # Canonicalize provided steps via your helper
    $available = @($Steps | ForEach-Object { Normalize-StepName $_ })

    if (-not $NonInteractive) {
        Write-Host "[PLAN] Available steps (default order): $($available -join ' → ')"
        $skipAns = (Read-Host "Do you want to modify resolution plan? (y/N)").Trim()
        if ($skipAns -match '^(?i:n|N|No|no)$') {
            return
        }

        # Ask which steps to skip, one by one
        $skipMap = @{}
        foreach ($s in $available) {
            $skipAns = (Read-Host "Skip step '$s'? (y/N)").Trim()
            if ($skipAns -match '^(?i:y|yes)$') {
                $reason = (Read-Host "Reason to record for skipping '$s' (default: 'Skipped by user')").Trim()
                if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'Skipped by user' }
                $skipMap[$s] = $reason
                Write-Host "[PLAN] Marked '$s' to be skipped. Reason: $reason"
            }
        }

        $global:ResolutionOrder = $available
        $global:SkipSteps       = $skipMap

        Write-Host "[PLAN] Final resolution order: $($global:ResolutionOrder -join ' → ')"
        if ($global:SkipSteps.Count -gt 0) {
            $pairs = $global:SkipSteps.Keys | ForEach-Object { "$_ (`"$($global:SkipSteps[$_])`")" }
            Write-Host "[PLAN] Steps to skip: $($pairs -join ', ')"
        } else {
            Write-Host "[PLAN] No steps are marked to skip."
        }
        return
    }

    # ---- Non-interactive mode (kept for completeness/back-compat) ----
    $global:ResolutionOrder = $available
    $global:SkipSteps = @{}
    foreach ($k in $Skip.Keys) {
        $canon = Normalize-StepName $k
        $global:SkipSteps[$canon] = [string]$Skip[$k]
    }
    Write-Host "[PLAN] (NonInteractive) Resolution order: $($global:ResolutionOrder -join ' → ')"
    if ($global:SkipSteps.Count -gt 0) {
        $pairs = $global:SkipSteps.Keys | ForEach-Object { "$_ (`"$($global:SkipSteps[$_])`")" }
        Write-Host "[PLAN] (NonInteractive) Steps to skip: $($pairs -join ', ')"
    } else {
        Write-Host "[PLAN] (NonInteractive) No steps are marked to skip."
    }
}

# --- Keep-Awake (background job) + periodic local policy scrub ---------------
function Start-KeepAwakeJob {
    param(
        [int]$IntervalSeconds = 50,          # how often to send keep-awake hints / jiggle
        [int]$PolicyScrubIntervalSeconds = 30 # how often to remove local lock settings
    )
    Write-Host "`nEnabling keep awake session`n" -ForegroundColor Cyan
    $jobName = 'AutoOps-KeepAwake'
    $existing = Get-Job -Name $jobName -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' }
    if ($existing) { Write-Host "[AWAKE] Job already running (Id=$($existing.Id))."; return $existing }

    Write-Host "[AWAKE] Starting keep-awake background job…"
    $script = {
        # --- imports for SetThreadExecutionState + tiny cursor jiggle
        Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NativeMethods {
  [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
}
"@;

        $ES_CONTINUOUS       = 0x80000000
        $ES_SYSTEM_REQUIRED  = 0x00000001
        $ES_DISPLAY_REQUIRED = 0x00000002

        # registry targets
        $hklmPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        $hklmName = 'InactivityTimeoutSecs'
        $hkcuPath = 'HKCU:\Control Panel\Desktop'

        # admin check (HKLM removal requires elevation)
        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
                   ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

        function Scrub-LocalLock {
            param([bool]$Admin)
            # Remove local inactivity limit (HKLM) if possible
            if ($Admin) {
                try { if (Test-Path $hklmPath) { Remove-ItemProperty -Path $hklmPath -Name $hklmName -ErrorAction SilentlyContinue } } catch {}
            }
            # Force-disable current user's screensaver
            try { Set-ItemProperty -Path $hkcuPath -Name 'ScreenSaveActive'    -Value '0' -Force } catch {}
            try { Set-ItemProperty -Path $hkcuPath -Name 'ScreenSaverIsSecure' -Value '0' -Force } catch {}
            try { Set-ItemProperty -Path $hkcuPath -Name 'ScreenSaveTimeOut'   -Value '0' -Force } catch {}
        }

        # initial scrub
        Scrub-LocalLock -Admin:$isAdmin

        $lastScrub = Get-Date
        while ($true) {
            # 1) Power/display hint (doesn't steal focus)
            [Win32.NativeMethods]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED -bor $ES_DISPLAY_REQUIRED) | Out-Null

            # 2) Tiny cursor jiggle (counts as input)
            try {
                $p = New-Object Win32.NativeMethods+POINT
                if ([Win32.NativeMethods]::GetCursorPos([ref]$p)) {
                    [Win32.NativeMethods]::SetCursorPos($p.X+1, $p.Y) | Out-Null
                    [Win32.NativeMethods]::SetCursorPos($p.X,   $p.Y) | Out-Null
                }
            } catch {}

            # 3) periodic re-scrub of local lock settings (in case of refresh)
            if ( ((Get-Date) - $lastScrub).TotalSeconds -ge $using:PolicyScrubIntervalSeconds ) {
                Scrub-LocalLock -Admin:$isAdmin
                $lastScrub = Get-Date
            }

            Start-Sleep -Seconds $using:IntervalSeconds
        }
    }

    $job = Start-Job -Name $jobName -ScriptBlock $script
    Write-Host "[AWAKE] Job started (Id=$($job.Id))."
    return $job
}

function Stop-KeepAwakeJob {
    $jobName = 'AutoOps-KeepAwake'
    $job = Get-Job -Name $jobName -ErrorAction SilentlyContinue
    if ($job) {
        Write-Host "[AWAKE] Stopping keep-awake job (Id=$($job.Id))…"
        Stop-Job -Id $job.Id -Force -ErrorAction SilentlyContinue
        Remove-Job -Id $job.Id -Force -ErrorAction SilentlyContinue
        Write-Host "[AWAKE] Keep-awake job stopped."
    } else {
        Write-Host "[AWAKE] No keep-awake job to stop."
    }
}

function Enable-KeepAwakeForSession {
    $job = Start-KeepAwakeJob -IntervalSeconds 45 -PolicyScrubIntervalSeconds 30
    if (-not (Get-EventSubscriber -SourceIdentifier PowerShell.Exiting -ErrorAction SilentlyContinue)) {
        Register-EngineEvent PowerShell.Exiting -Action {
            Stop-Job -Name 'AutoOps-KeepAwake' -Force -ErrorAction SilentlyContinue
            Remove-Job -Name 'AutoOps-KeepAwake' -Force -ErrorAction SilentlyContinue
        } | Out-Null
    }
    return $job
}

# ---------------------------------------------------------------------------

function To-BashSingleQuoted {
    param([Parameter(Mandatory)][string]$s)
    "'" + ($s -replace "'", "'\''") + "'"
}

function Ensure-SshAccess {
    param(
        [Parameter(Mandatory)][string]$Server,
        [string]$User = $global:linuxUser
    )
    
    Write-Host "`n[SSH] Ensuring access for $User@$Server`n" -ForegroundColor Cyan


    $sshDir           = Join-Path $env:USERPROFILE ".ssh"
    $sshPrivateKey    = Join-Path $sshDir "id_rsa"
    $sshPublicKey     = Join-Path $sshDir "id_rsa.pub"
    $knownHostsPath   = Join-Path $sshDir "known_hosts"

    if (-not (Test-Path $sshDir))       { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
    if (-not (Test-Path $knownHostsPath)) { New-Item -ItemType File      -Path $knownHostsPath -Force | Out-Null }

    
    # Ensure keypair
    if (-not (Test-Path $sshPrivateKey)) {
        return [pscustomobject]@{ Status="fail"; Message="SSH private key has not been created yet"; Server=$Server; User=$User }
    }

    # Quick connectivity check (non-interactive)
    $check = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -o BatchMode=yes -o ConnectTimeout=5 "$User@$Server" "echo OK" 2>&1
    if ($check -match "OK") {
        Write-Host "[SSH] Already configured for $User@$Server"
        return [pscustomobject]@{ Status="ok"; Message="SSH already configured."; Server=$Server; User=$User }
    }else {
        Write-Host "[SSH][WARN] Connectivity fail:  $check"
        # Remove stale known_hosts entry & (re)add current host key
        ssh-keygen -R "$Server" 2>$null | Out-Null
        ssh-keyscan -H "$Server" 2>$null | ForEach-Object {
            Add-Content -Path $knownHostsPath -Value $_
        }

        $check = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -q "$User@$Server" "echo OK" 2>&1
        if ($check -match "OK") {
            Write-Host "[SSH] Already configured for $User@$Server"
            return [pscustomobject]@{ Status="ok"; Message="SSH already configured."; Server=$Server; User=$User }
        }

       return [pscustomobject]@{ Status="fail"; Message="Connectivity failed: $check"; Server=$Server; User=$User }
    }
}
function Sshkeydist {
    param(
        [Parameter(Mandatory)][string]$Server,
        [string]$User = $global:linuxUser
    )
   `Write-Host "`n[SSH][BEGIN] Sshkeydist(Server='$Server', User='$User')`n" -ForegroundColor Cyan

    Write-Host "[SSH] Preparing local ~/.ssh paths…"
    $sshDir         = Join-Path $env:USERPROFILE ".ssh"
    $sshPrivateKey  = Join-Path $sshDir "id_rsa"
    $sshPublicKey   = Join-Path $sshDir "id_rsa.pub"
    $knownHostsPath = Join-Path $sshDir "known_hosts"
    


    Write-Host "[SSH] sshDir=$sshDir"
    Write-Host "[SSH] sshPrivateKey=$sshPrivateKey"
    Write-Host "[SSH] sshPublicKey=$sshPublicKey"
    Write-Host "[SSH] knownHostsPath=$knownHostsPath"

    # Quick connectivity check (non-interactive)
    Write-Host "[SSH] Probing non-interactive connectivity to $User@$Server…"
    $check = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -o BatchMode=yes -o ConnectTimeout=5 "$User@$Server" "echo OK" 2>&1
    Write-Host "[SSH] Probe output: $check"
    if ($check -match "OK") {
        Write-Host "[SSH] Already configured for $User@$Server"
        Write-Host "[SSH][END] Sshkeydist → ok (no interactive step needed)"
        return [pscustomobject]@{ Status="ok"; Message="SSH already configured."; Server=$Server; User=$User }
    }

    if (-not (Test-Path $sshDir)) {
        Write-Host "[SSH] ~/.ssh not found → creating…"
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    } else {
        Write-Host "[SSH] ~/.ssh exists."
    }

    if (-not (Test-Path $knownHostsPath)) {
        Write-Host "[SSH] known_hosts not found → creating empty file…"
        New-Item -ItemType File -Path $knownHostsPath -Force | Out-Null
    } else {
        Write-Host "[SSH] known_hosts exists."
    }

    # Remove stale known_hosts entry & (re)add current host key
    Write-Host "[SSH] Purging stale host key from known_hosts (ssh-keygen -R $Server)…"
    ssh-keygen -R "$Server" 2>$null | Out-Null
    Write-Host "[SSH] Re-scanning host key (ssh-keyscan -H $Server)…"
    ssh-keyscan -H "$Server" 2>$null | ForEach-Object {
        Add-Content -Path $knownHostsPath -Value $_
    }
    Write-Host "[SSH] Host key added to known_hosts."

    $check = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -o BatchMode=yes -o ConnectTimeout=5 "$User@$Server" "echo OK" 2>&1
    Write-Host "[SSH] Probe output: $check"
    if ($check -match "OK") {
        Write-Host "[SSH] Already configured for $User@$Server"
        Write-Host "[SSH][END] Sshkeydist → ok (no interactive step needed)"
        return [pscustomobject]@{ Status="ok"; Message="SSH already configured."; Server=$Server; User=$User }
    }

    # Ensure keypair
    if (-not (Test-Path $sshPrivateKey)) {
        Write-Host "[SSH] Private key not found → generating new keypair (rsa 4096)…"
        ssh-keygen -f $sshPrivateKey
        Write-Host "[SSH] Keypair generated."
    } else {
        Write-Host "[SSH] Private key exists."
    }


    # Interactive pubkey copy (lets you type the password once)
    Write-Host "[SSH] Non-interactive probe failed → starting interactive pubkey copy."
    $guid        = [guid]::NewGuid().ToString()
    $tempScript  = "$env:TEMP\SendSshKey_$guid.ps1"
    $outputPath  = "$env:TEMP\SendSshKeyResult_$guid.txt"
    Write-Host "[SSH] tempScript=$tempScript"
    Write-Host "[SSH] outputPath=$outputPath"

    $script      = @"
`$ErrorActionPreference = 'Stop'
Write-Host '[SSH][CHILD] Sending SSH key to $User@$Server…'
`$pubKey = Get-Content "$sshPublicKey" -Raw
try {
    Write-Host '[SSH][CHILD] Appending key to ~/.ssh/authorized_keys (remote)…'
    `$pubKey | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no "$User@$Server" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys;"
    Write-Host '[SSH][CHILD] Key append command finished.'
    "`$(Get-Date -Format o) [SUCCESS] SSH key sent" | Out-File "$outputPath" -Encoding UTF8
} catch {
    Write-Host ('[SSH][CHILD][FAIL] ' + `$_.Exception.Message)
    "`$(Get-Date -Format o) [FAIL] `$($_.Exception.Message)" | Out-File "$outputPath" -Encoding UTF8
}
"@

    Write-Host "[SSH] Writing child script to disk…"
    $script | Set-Content -Path $tempScript -Encoding UTF8
    Write-Host "[SSH] Launching child PowerShell for interactive key copy…"
    Start-Process powershell -ArgumentList "-NoExit","-ExecutionPolicy Bypass","-File","`"$tempScript`"" -Wait
    Write-Host "[SSH] Child process finished. Inspecting result file…"

    $status  = "error"
    $message = "No output from SSH key script."
    if (Test-Path $outputPath) {
        $raw = Get-Content $outputPath -Raw
        Write-Host "[SSH] Result file contents:`n$raw"
        if ($raw -match "\[SUCCESS\]") {
            $status = "ok";   $message = "SSH key sent successfully."
            Write-Host "[SSH] Key copy reported SUCCESS."
        } else {
            $status = "fail"; $message = "Failed to send SSH key: $raw"
            Write-Host "[SSH] Key copy reported FAIL."
        }
        Write-Host "[SSH] Cleaning up result file…"
        Remove-Item $outputPath -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "[SSH][WARN] Result file not found: $outputPath"
    }

    Write-Host "[SSH] Cleaning up temp script…"
    Remove-Item $tempScript -Force -ErrorAction SilentlyContinue

    # Re-test after interactive copy
    if ($status -eq "ok") {
        Write-Host "[SSH] Re-testing non-interactive connectivity to $User@$Server…"
        $check2 = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -o BatchMode=yes -o ConnectTimeout=5 "$User@$Server" "echo OK" 2>&1
        Write-Host "[SSH] Post-copy probe output: $check2"
        if ($check2 -match "OK") {
            Write-Host "[SSH] Connectivity established for $User@$Server"
            Write-Host "[SSH][END] Sshkeydist → ok"
            return [pscustomobject]@{ Status="ok"; Message=$message; Server=$Server; User=$User }
        } else {
            Write-Host "[SSH][WARN] Post-copy connectivity still failing."
            Write-Host "[SSH][END] Sshkeydist → fail (post-copy check)"
            exit
        }
    } else {
        Write-Host "[SSH][WARN] Key copy failed: $message"
        Write-Host "[SSH][END] Sshkeydist → fail (copy stage)"
        exit
    }
}
function Get-PlainTextFromSecure {
    param([Parameter(Mandatory)][securestring]$Secure)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
function Read-RemoteSudoPassword {
    param(
        [string]$Server = $global:sshServer,
        [string]$User   = $global:linuxUser,
        [switch]$AllocateTty  # pass -AllocateTty if your sudoers requires a TTY
    )
    Write-Host "`nSudo Password configuration" -ForegroundColor Cyan
    Write-Host "[SUDO] You can press Ctrl+C to abort." -ForegroundColor Yellow

    while ($true) {
        $sec   = Read-Host "Enter sudo password for $User" -AsSecureString
        $plain = Get-PlainTextFromSecure $sec

        if ([string]::IsNullOrWhiteSpace($plain)) {
            Write-Host "[SUDO][WARN] Empty password entered; please try again."
            continue
        }

        Write-Host "[SUDO] Verifying password by priming sudo on $Server…"
        try {
            $prime = Start-RemoteSudoSession -Server $Server -User $User -PlainPassword $plain -AllocateTty:$AllocateTty.IsPresent
        } catch {
            Write-Host "[SUDO][ERROR] Prime attempt raised an exception: $($_.Exception.Message)"
            continue
        }

        if ($prime.status -eq 'ok') {
            Set-Variable -Name SudoPassword -Value $plain -Scope Global -Force
            Write-Host "[SUDO] Password verified and stored for this run."
            return $plain
        } else {
            Write-Host "[SUDO][FAIL] Could not prime sudo: $($prime.output)"
            Write-Host "[SUDO] Please try again."
        }
    }
}

function Start-RemoteSudoSession {
    param(
        [Parameter(Mandatory)][string]$Server,           # jump host (e.g. $global:sshServer)
        [string]$User = $global:linuxUser,
        [Parameter(Mandatory)][string]$PlainPassword,    # from Read-RemoteSudoPassword
        [switch]$AllocateTty
    )
    $sshDir         = Join-Path $env:USERPROFILE ".ssh"
    $sshPrivateKey  = Join-Path $sshDir "id_rsa"
    $sshPublicKey   = Join-Path $sshDir "id_rsa.pub"
    $knownHostsPath = Join-Path $sshDir "known_hosts"

    $remote = "$User@$Server"
    $pwQ    = To-BashSingleQuoted $PlainPassword
    

    $check = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -q "$User@$Server" "echo OK" 2>&1
    Write-Host "[SSH] Probe output: $check"
    if ($check -match "OK") {
        Write-Host "[SSH] Connected to $User@$Server"
    }
    else {
        # Remove stale known_hosts entry & (re)add current host key
        Write-Host "[SSH] Purging stale host key from known_hosts (ssh-keygen -R $Server)…"
        ssh-keygen -R "$Server" 2>$null | Out-Null
        Write-Host "[SSH] Re-scanning host key (ssh-keyscan -H $Server)…"
        ssh-keyscan -H "$Server" 2>$null | ForEach-Object {
            Add-Content -Path $knownHostsPath -Value $_
        }
    }

    # 2) Prime sudo timestamp: sudo -n true || echo $pw | sudo -S -v
$bash = @"
sudo -n true 2>/dev/null || ( echo __PASSWORD__ | sudo -S -p '' -v )
sudo -n true && echo PRIMED || echo FAIL
"@ -replace "__PASSWORD__", $pwQ -replace "\r?\n", " ; "
    $wrapped = "bash -lc " + (To-BashSingleQuoted $bash)

    $args = @()
    if ($AllocateTty) { $args += '-tt' }   # add a TTY if your sudoers has requiretty
    $args += '-q', $remote, $wrapped

    $out = & ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no @args 2>&1
    if ($out -match 'PRIMED') {
        Write-Host "[SUDO] Primed on $Server for $User."
        return @{ status="ok"; server=$Server; user=$User; output=($out -join "`n") }
    } else {
        Write-Host "[SUDO][FAIL] Could not prime sudo on $Server."
        return @{ status="fail"; server=$Server; user=$User; output=($out -join "`n") }
    }
}

# ===== UTILS =====
function Write-OutputToResponse {
    param (
        [System.Net.HttpListenerResponse] $Response,
        [string] $Content
    )
    $Response.AddHeader("Access-Control-Allow-Origin", "*")
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $Response.ContentLength64 = $buffer.Length
    $Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Response.OutputStream.Close()
}

function Get-JsonBody {
    param ([System.Net.HttpListenerRequest] $Request)
    try {
        $reader  = New-Object IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
        $rawBody = $reader.ReadToEnd(); $reader.Close()
        return $rawBody | ConvertFrom-Json
    } catch { return $null }
}
# Wrap a string for: bash -lc '...'
function To-BashSingleQuoted {
    param([Parameter(Mandatory)][string]$s)
    "'" + ($s -replace "'", "'\''") + "'"
}

# Where to store local logs/PIDs for each host
function Get-LocalSolPaths {
    param([Parameter(Mandatory)][string]$HostShort)
    $dir = Join-Path $PSScriptRoot "sol-logs"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [pscustomobject]@{
        LogFile = (Join-Path $dir "sol_$HostShort.log")
        PidFile = (Join-Path $dir "sol_$HostShort.pid")
    }
}


# Start a LOCAL background ssh that runs ipmitool SOL on the remote, streaming to a LOCAL log
function Start-LocalSolCapture {
    param(
        [Parameter(Mandatory)][string]$HostShort,
        [Parameter(Mandatory)][string]$MgmtIP,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Pass,
        [string[]]$SshServers  # optional pool
    )

    # ----- choose a working jump host -----
    $pool = @()
    if ($SshServers -and $SshServers.Count) { $pool = $SshServers }
    elseif ($global:sshServers -and $global:sshServers.Count) { $pool = $global:sshServers }
    elseif ($global:sshServer) { $pool = @($global:sshServer) }
    if (-not $pool.Count) { throw "No SSH server(s) provided. Set -SshServers or `$global:sshServers / `$global:sshServer." }

    $pickedSsh = $null
    foreach ($candidate in (Get-Random -InputObject $pool -Count $pool.Count)) {
        $probe = Ensure-SshAccess -Server $candidate -User $global:linuxUser
        Write-Host "[SOL][SSH] Probe $candidate â†’ $($probe.Status)"
        if ($probe.Status -eq 'ok') { $pickedSsh = $candidate; break }
    }
    if (-not $pickedSsh) { throw "No reachable SSH server from pool: $($pool -join ', ')" }
    $remote = "$global:linuxUser@$pickedSsh"
    Write-Host "[SOL][LOCAL] Using SSH jump host: $pickedSsh"

    # ----- local paths -----
    $dir = Join-Path $PSScriptRoot "sol-logs"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $logFile = Join-Path $dir "sol_$HostShort.log"
    $errFile = Join-Path $dir "sol_$HostShort.err"
    $pidFile = Join-Path $dir "sol_$HostShort.pid"

    # stop any previous capture for this host
    if (Test-Path $pidFile) {
        $old = (Get-Content $pidFile -ErrorAction SilentlyContinue) -as [int]
        if ($old) { Stop-Process -Id $old -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 300 }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $logFile,$errFile -Force -ErrorAction SilentlyContinue

    # ----- remote command (self-healing loop; no interaction) -----
    # - Deactivate any stale SOL, then continuously (re)activate.
    # - If BMC drops/keepalive fails, it retries after 2s.
    $remoteCmd = @"
( ipmitool -I lanplus -H $MgmtIP -U $User -P $Pass sol deactivate >/dev/null 2>&1 || true );
while :; do
  ipmitool -I lanplus -H $MgmtIP -U $User -P $Pass sol activate;
  echo '[SOL] ipmitool exited, retrying in 2s...' 1>&2;
  sleep 2;
done
"@ -replace "`r?`n",' '
    $wrapped = "bash -lc '" + ($remoteCmd -replace "'", "'\''") + "'"

    # ----- launch background ssh (fully non-interactive; detached from stdin) -----
    $sshArgs = @(
        '-n',                    # disconnect stdin (prevents ssh waiting for input)
        '-tt',                   # force TTY so ipmitool SOL behaves correctly
        '-q',
        '-o','BatchMode=yes',    # never ask for passwords/passphrases
        '-o','StrictHostKeyChecking=yes',
        '-o','ConnectTimeout=8',
        '-o','ServerAliveInterval=20',
        '-o','ServerAliveCountMax=2',
        $remote,
        $wrapped
    )

    $proc = Start-Process -FilePath "ssh" `
                          -ArgumentList $sshArgs `
                          -WindowStyle Hidden `
                          -RedirectStandardOutput $logFile `
                          -RedirectStandardError  $errFile `
                          -PassThru

    $proc.Id | Out-File -FilePath $pidFile -Encoding ascii -Force
    Write-Host "[SOL][LOCAL] Started for $HostShort via $pickedSsh â†’ out:$logFile err:$errFile (pid $($proc.Id))"

    return @{
        status  = "ok"
        pid     = $proc.Id
        log     = $logFile
        err     = $errFile
        pidfile = $pidFile
        remote  = $pickedSsh
    }
}
function Stop-LocalSolCaptureAndFetch {
    param([Parameter(Mandatory)][string]$HostShort)

    $dir     = Join-Path $PSScriptRoot "sol-logs"
    $logFile = Join-Path $dir "sol_$HostShort.log"
    $errFile = Join-Path $dir "sol_$HostShort.err"
    $pidFile = Join-Path $dir "sol_$HostShort.pid"

    $sshPid = $null
    if (Test-Path $pidFile) {
        $pidText = Get-Content $pidFile -Raw -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($pidText)) {
            try {
                [int]$sshPid = $pidText.Trim()
            } catch { $sshPid = $null }
        }

        if ($sshPid) {
            try {
                $p = Get-Process -Id $sshPid -ErrorAction SilentlyContinue
                if ($p) {
                    Stop-Process -Id $sshPid -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 300
                }
            } catch { }
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }

    $stdout = if (Test-Path $logFile) { Get-Content $logFile -Raw -ErrorAction SilentlyContinue } else { "" }
    $stderr = if (Test-Path $errFile) { Get-Content $errFile -Raw -ErrorAction SilentlyContinue } else { "" }
    $text   = if ($stderr) { "$stdout`n--- STDERR ---`n$stderr" } else { $stdout }

    Write-Host "[SOL][LOCAL] Harvested for $HostShort â†’ outLen=$($stdout.Length) errLen=$($stderr.Length) killedPid=$sshPid"
    return @{ status="ok"; text=$text; log=$logFile; err=$errFile; killedPid=$sshPid }
}
# ===== one-time cleanup (optional) =====
Remove-Item Function:Save-HostRecord -ErrorAction Ignore
Remove-Item Function:Add-ResolutionStep -ErrorAction Ignore

# ===== string helpers =====
function Format-Psd1String {
    param([string]$s)
    if ($null -eq $s) { return "''" }
    if ($s -match "(`r`n|`n)") { return "@'`n$s`n'@" }
    return "'$($s -replace '''','''''')'"
}
function Format-Psd1-LastResolutionBlock {
    param($lr, [int]$indent = 4)
    $pad  = ' ' * $indent
    $pad2 = ' ' * ($indent + 4)
    if ($null -eq $lr) { return "$pad`$null" }
    $step = ($lr.Step   -replace '''','''''')
    $time = ($lr.Time   -replace '''','''''')
    $stat = ($lr.Status -replace '''','''''')
    $note = (([string]$lr.Note) -replace '''','''''')
@"
$pad@{
$pad2 Step   = '$step'
$pad2 Time   = '$time'
$pad2 Status = '$stat'
$pad2 Note   = '$note'
$pad}
"@
}

# ===== object helper =====
function ConvertTo-HashtableDeep {
    param([Parameter(ValueFromPipeline=$true)] $InputObject)
    if ($null -eq $InputObject) { return @{} }
    if ($InputObject -is [hashtable]) { return $InputObject }
    if ($InputObject -is [System.Collections.Specialized.OrderedDictionary]) {
        $ht = @{}; foreach ($k in $InputObject.Keys) { $ht[$k] = ConvertTo-HashtableDeep $InputObject[$k] }; return $ht
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $arr = @(); foreach ($item in $InputObject) { $arr += ,(ConvertTo-HashtableDeep $item) }; return ,$arr
    }
    if ($InputObject -is [psobject]) {
        $ht = @{}; foreach ($p in $InputObject.PSObject.Properties) { $ht[$p.Name] = ConvertTo-HashtableDeep $p.Value }; return $ht
    }
    return $InputObject
}

# ===== host file path =====
function Get-HostRecordPath {
    param([Parameter(Mandatory)][string]$HostShort)
    $dir = Join-Path $PSScriptRoot "hosts"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir "$HostShort.psd1")
}

# ===== record schema =====
function New-HostRecord {
    return @{
        IloAfterRebootOutput = ''          # string
        ResolutionSteps      = @()         # string[]
        TroubleshootingSteps = @()         # string[]
        AllQueryResult       = ''          # string
        Online               = 'Unknown'   # 'Online' | 'Offline' | 'Unknown'
        LastResolution       = $null       # @{ Step; Time; Status; Note }
    }
}

function Load-HostRecord {
    param([Parameter(Mandatory)][string]$HostShort)
    $path = Get-HostRecordPath -HostShort $HostShort
    if (-not (Test-Path $path)) {
        $rec = New-HostRecord
        Save-HostRecord -HostShort $HostShort -Record $rec
        return $rec
    }
    try {
        $rec = ConvertTo-HashtableDeep (Import-PowerShellDataFile -Path $path)
        foreach ($k in 'IloAfterRebootOutput','ResolutionSteps','TroubleshootingSteps','AllQueryResult','Online','LastResolution') {
            if (-not $rec.ContainsKey($k)) {
                switch ($k) {
                    'ResolutionSteps'      { $rec[$k] = @() }
                    'TroubleshootingSteps' { $rec[$k] = @() }
                    'Online'               { $rec[$k] = 'Unknown' }
                    'LastResolution'       { $rec[$k] = $null }
                    default                { $rec[$k] = '' }
                }
            }
        }
        if ($rec['ResolutionSteps'] -is [string])      { $rec['ResolutionSteps']      = @($rec['ResolutionSteps']) }
        if ($rec['TroubleshootingSteps'] -is [string]) { $rec['TroubleshootingSteps'] = @($rec['TroubleshootingSteps']) }
        if ($rec['LastResolution'] -ne $null) {
            $lr = ConvertTo-HashtableDeep $rec['LastResolution']
            foreach ($f in 'Step','Time','Status','Note') { if (-not $lr.ContainsKey($f)) { $lr[$f] = '' } }
            $rec['LastResolution'] = $lr
        }
        return $rec
    } catch {
        return New-HostRecord
    }
}

function Save-HostRecord {
    param(
        [Parameter(Mandatory)][string]$HostShort,
        [Parameter(Mandatory)][object]$Record
    )
    $rec = ConvertTo-HashtableDeep $Record
    foreach ($k in 'IloAfterRebootOutput','ResolutionSteps','TroubleshootingSteps','AllQueryResult','Online','LastResolution') {
        if (-not $rec.ContainsKey($k)) {
            switch ($k) {
                'ResolutionSteps'      { $rec[$k] = @() }
                'TroubleshootingSteps' { $rec[$k] = @() }
                'Online'               { $rec[$k] = 'Unknown' }
                'LastResolution'       { $rec[$k] = $null }
                default                { $rec[$k] = '' }
            }
        }
    }
    if ($rec['ResolutionSteps'] -is [string])      { $rec['ResolutionSteps']      = @($rec['ResolutionSteps']) }
    if ($rec['TroubleshootingSteps'] -is [string]) { $rec['TroubleshootingSteps'] = @($rec['TroubleshootingSteps']) }
    if ($rec['LastResolution'] -ne $null) {
        $lr = ConvertTo-HashtableDeep $rec['LastResolution']
        foreach ($f in 'Step','Time','Status','Note') { if (-not $lr.ContainsKey($f)) { $lr[$f] = '' } }
        $rec['LastResolution'] = $lr
    }

    $path = Get-HostRecordPath -HostShort $HostShort
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('@{')
    [void]$sb.AppendLine("    IloAfterRebootOutput = $(Format-Psd1String $rec.IloAfterRebootOutput)")
    [void]$sb.AppendLine("    ResolutionSteps      = @(")
    foreach ($s in @($rec.ResolutionSteps))      { [void]$sb.AppendLine("        '$(($s -replace '''',''''''))'") }
    [void]$sb.AppendLine("    )")
    [void]$sb.AppendLine("    TroubleshootingSteps = @(")
    foreach ($s in @($rec.TroubleshootingSteps)) { [void]$sb.AppendLine("        '$(($s -replace '''',''''''))'") }
    [void]$sb.AppendLine("    )")
    [void]$sb.AppendLine("    AllQueryResult       = $(Format-Psd1String $rec.AllQueryResult)")
    [void]$sb.AppendLine("    Online               = '$(($rec.Online -replace '''',''''''))'")
    [void]$sb.AppendLine("    LastResolution        = $(Format-Psd1-LastResolutionBlock $rec.LastResolution)")
    [void]$sb.AppendLine('}')
    $sb.ToString() | Set-Content -Path $path -Encoding UTF8
}



function Normalize-StepName {
    param([string]$Name)
    switch -Regex ($Name) {
        '^(poweron)$'                 { 'PowerOn' }
        '^(reboot)$'                           { 'Reboot' }
        '^(ac\s*cycle|accycle|accycleblades)$' { 'AcCycle' }
        '^(press\s*key|presskey)$'             { 'PressKey' }
        '^(bmc\s*reset|bmcrestart)$'           { 'BmcReset' }
        '^(cobbler\s*check|cobblercheck)$'           { 'CobblerCheck' }
        '^(legacy\s*reboot|legacyreboot)$'           { 'LegacyReboot' }
        '^(pxe\s*reset1|pxerestart1)$'           { 'PxeReset1' }
        '^(pxe\s*reset2|pxerestart2)$'           { 'PxeReset2' }
        default { $Name }
    }
}
function Test-ActionSuccess {
    param([string]$Output)

    if ($Output -match '(?i)Unable to create Redfish session|Action failed|\[Fail\]|Max retries exceeded with url') {
        return $false
    } else {
        return $true
    }
}

function Last-Step-Failed   { param([hashtable]$Record) return ($Record.LastResolution -and $Record.LastResolution.Status -eq 'Fail') }

function Get-LastResolutionTimeUtc {
    param([hashtable]$Record)
    if (-not $Record.LastResolution) { return $null }
    $raw = [string]$Record.LastResolution.Time
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return ([DateTimeOffset]::ParseExact($raw,'o',[Globalization.CultureInfo]::InvariantCulture)).UtcDateTime }
    catch { try { return ([DateTimeOffset]::Parse($raw,[Globalization.CultureInfo]::InvariantCulture)).UtcDateTime } catch { return $null } }
}
function Should-SkipByLastResolution {
    param([hashtable]$Record,[int]$Minutes=10)
    $lastUtc = Get-LastResolutionTimeUtc -Record $Record
    if ($null -eq $lastUtc) { return @{ Skip=$false; Reason='' } }
    $cutoff = (Get-Date).ToUniversalTime().AddMinutes(-$Minutes)
    if ($lastUtc -gt $cutoff) {
        $age = [int]([Math]::Round(((Get-Date).ToUniversalTime() - $lastUtc).TotalMinutes))
        return @{ Skip=$true; Reason="LastResolution within ${Minutes}m (${age}m ago)" }
    }
    return @{ Skip=$false; Reason='' }
}
function Next-Sequential-Step {
    param([hashtable]$Record)
    $done = @()
    if ($Record.TroubleshootingSteps) { $done = @($Record.TroubleshootingSteps | ForEach-Object { Normalize-StepName $_ }) }
    foreach ($step in $global:ResolutionOrder) { if ($done -notcontains $step) { return $step } }
    return $null
}

function Next-Sequential-Step-Rebuild {
    param([hashtable]$Record)
    $done = @()
    if ($Record.TroubleshootingSteps) { $done = @($Record.TroubleshootingSteps | ForEach-Object { Normalize-StepName $_ }) }
    foreach ($step in $global:ResolutionOrderRebuild) { if ($done -notcontains $step) { return $step } }
    return $null
}


function Add-ResolutionStep {
    param([hashtable]$Record,[string]$ActionName,[string]$Status,[string]$Note='')
    $canon = Normalize-StepName $ActionName
    if (-not $Record.ResolutionSteps)      { $Record.ResolutionSteps      = @() }
    if (-not $Record.TroubleshootingSteps) { $Record.TroubleshootingSteps = @() }
    $ts = (Get-Date).ToString('o')
    if ($Record.TroubleshootingSteps -notcontains $canon) { $Record.TroubleshootingSteps += $canon }
    $Record.ResolutionSteps += "AUTO-$canon @ $ts [$Status] $Note".Trim()
    $Record.LastResolution = @{ Step=$canon; Time=$ts; Status=$Status; Note=$Note }
}

function Get-SolPaths {
    param([Parameter(Mandatory)][string]$HostShort)
    return @{ Log = "/tmp/jdcruzlo/sol_${HostShort}.log"; Pid = "/tmp/jdcruzlo/sol_${HostShort}.pid" }
}
function Stop-RemoteSolCaptureAndFetch {
    param([Parameter(Mandatory)][string]$HostShort)
    $remote  = "$global:linuxUser@$global:sshServer"
    $logFile = "/tmp/sol_${HostShort}.log"
    $pidFile = "/tmp/sol_${HostShort}.pid"
    $tpl = @'
p=$( [ -f "{PIDFILE}" ] && cat "{PIDFILE}" || true ); if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then kill -TERM "$p" 2>/dev/null || true; sleep 1; fi; rm -f "{PIDFILE}"; [ -f "{LOGFILE}" ] && cat "{LOGFILE}" || true
'@ -replace "\r?\n",' '
    $inner = $tpl.Replace('{PIDFILE}', $pidFile).Replace('{LOGFILE}', $logFile)
    $cmd   = "bash -lc " + (To-BashSingleQuoted $inner)
    $out   = ssh -q $remote $cmd 2>&1
    return @{ status="ok"; text=($out -join "`n"); log=$logFile; pidfile=$pidFile }
}


# ===== POST /init =====
function Handle-InitRequest {
    param (
        [System.Net.HttpListenerRequest] $Request,
        [System.Net.HttpListenerResponse] $Response
    )
    Write-Host "POST /init"
    $data = Get-JsonBody -Request $Request
    if (-not $data) {
        $Response.StatusCode = 400
        return Write-OutputToResponse $Response (@{ status = "error"; message = "Invalid JSON format" } | ConvertTo-Json -Compress)
    }
    $global:linuxUser = ($env:USERNAME -replace "^ad_", "")

    $Response.StatusCode = 200
    Write-OutputToResponse $Response (@{ status = "ok"; message = "Initialized for $($global:linuxUser)@$global:sshServer" } | ConvertTo-Json -Compress)
}


# ===== POST /send-ssh-key =====
function Handle-SendSshKey {
    param ([System.Net.HttpListenerResponse] $Response)
    Write-Host "POST /send-ssh-key"
    $server = $global:sshServer
    $user   = $global:linuxUser

    $res = Ensure-SshAccess -Server $server -User $user
    $Response.StatusCode = 200
    Write-OutputToResponse $Response (@{ status=$res.Status; message=$res.Message; server=$res.Server; user=$res.User } | ConvertTo-Json -Compress)
}

# ===== INTERNAL ACTIONS (no HTTP) =====
function Invoke-WorkaroundLogin {
    param([string[]]$Servers)
    Write-Host "== Action: WorkaroundLogin =="

    $remote    = "$global:linuxUser@$global:sshServer"
    $credsPath = Join-Path $PSScriptRoot "redfish_credentials.txt"
    if (-not (Test-Path $credsPath)) { throw "Missing credentials file: $credsPath" }

    $credentials = Get-Content $credsPath | Where-Object { $_ -match ',' } | ForEach-Object {
        $p = $_ -split ',', 2
        [PSCustomObject]@{ user = $p[0].Trim(); pass = $p[1].Trim() }
    }

    $results = @{}
    foreach ($hostname in $Servers) {
        $short = ($hostname -split '\.')[0]
        Write-Host "[WRK] Processing $short"

        $umatchCmd = "umatch nodes $short mgmt"
        $ipOut = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -q $remote $umatchCmd 2>&1
        if ($ipOut -notmatch '^\s*(\d+\.\d+\.\d+\.\d+)\s*$') {
            $results[$short] = "[Fail] umatch mgmt failed: $ipOut"
            continue
        }
        $ip = $matches[1]

        try {
            $dnsName = [System.Net.Dns]::GetHostEntry($ip).HostName
            if (-not $dnsName.StartsWith("mgmt-")) { $dnsName = "mgmt-$dnsName" }
        } catch {
            $results[$short] = "DNS resolution failed for IP $ip"
            continue
        }

        $final = ""; $ok = $false; $lastCmd = ""; $lastOut = ""
        foreach ($c in $credentials) {
            $cmd = "/nfs/adm/manager/tmp/magdy_workaround/workaround -m $dnsName -justexit -u $($c.user) -p $($c.pass)"
            Write-Host "[WRK] $short → $cmd"
            $out = (ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -q $remote $cmd 2>&1) -join "`n"
            $lastCmd = $cmd
            $lastOut = $out
            if ($out -notmatch "ERROR: Failed to login") { $final = $out; $ok = $true; break }
            $final = $out
        }

        if ($ok) {
            $results[$short] = @"
Press any Key error workaround.

$umatchCmd
$ipOut

/nfs/adm/manager/tmp/magdy_workaround/workaround -m $dnsName -justexit -u *user* -p *pass*
$lastOut
"@
        } else {
            $results[$short] = "[Fail] $final"
        }

        Write-Host "[WRK] Done $short (success=$ok)"
    }
    return $results
}
function Invoke-SetOneTimeBootWithRetry {
    param(
        [Parameter(Mandatory)][string]$Remote,   # e.g. "$global:linuxUser@$global:sshServer"
        [Parameter(Mandatory)][string]$hostname,    # short host name
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Pass,
        [int]$MaxTries = 15,
        [int]$SleepSeconds = 10
    )

    # Errors that mean BMC or network not ready yet -> wait and retry outer loop
    $connErr = '(?is)HTTPSConnectionPool|Max\s+retries\s+exceeded|Failed\s+to\s+establish\s+a\s+new\s+connection|No\s+route\s+to\s+host|Maximum\s+sessions\s+reached|Read\s+timed\s+out|Connection\s+timed\s+out'
    # Error that means bad/blocked credentials -> try a different username/password
    $credErr = '(?is)Unable\s+to\s+create\s+Redfish\s+session.*Check\s+credentials'

    # Load additional credentials (user,pass) from redfish_credentials.txt in script folder
    $credsPath = Join-Path $PSScriptRoot 'redfish_credentials.txt'
    $fileCreds = @()
    if (Test-Path $credsPath) {
        $fileCreds = Get-Content $credsPath | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_)) {
                $p = $_.Split(',')
                if ($p.Count -ge 2) {
                    [PSCustomObject]@{ user = $p[0].Trim(); pass = $p[1].Trim() }
                }
            }
        } | Where-Object { $_ -ne $null }
    }

    # Build ordered list of credentials: prefer the explicit -User/-Pass first, then the file (deduped)
    $credList = New-Object System.Collections.Generic.List[object]
    $credList.Add([PSCustomObject]@{ user = $User; pass = $Pass })
    foreach ($c in $fileCreds) {
        if (-not ($c.user -eq $User -and $c.pass -eq $Pass)) { $credList.Add($c) }
    }

    $last = ""
    for ($i = 1; $i -le $MaxTries; $i++) {
        Write-Host "[SETBOOT][$Short] Attempt $i/$MaxTries"

        $anyCredWorked = $false
        $sawConnErr    = $false
        $lastCmd = ""
        $lastOut = ""

        foreach ($cred in $credList) {
            $u = $cred.user
            $p = $cred.pass
            $cmd = "sudo /nfs/site/gen/adm/linuxset/hardware/firmware/support_scripts/redfish_mgmt_utility/redfish_mgmt.py -n $hostname --set_onetime_boot 'Pxe' 'Legacy' -u $User -p $Pass"
            $lastCmd = $cmd
            Write-Host "[SETBOOT][$Short] Run → $cmd"

            # -t for TTY; BatchMode yes so it fails fast if auth issues arise (ssh key should already be set)
            $out = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t -o BatchMode=yes $Remote $cmd
            $txt = $out -join "`n"
            $last = $txt
            $lastOut = $txt

            # If not a connection/BMC readiness error and not a credential error → treat as success
            if ($txt -notmatch $connErr -and $txt -notmatch $credErr) {
                Write-Host "[SETBOOT][$Short] Completed with user '$u'."
                return @"
$($lastCmd -replace [regex]::Escape($u), "*User*" -replace [regex]::Escape($p), "*Pass*")
$txt
"@
            }

            if ($txt -match $credErr) {
                Write-Host "[SETBOOT][$Short] Credential rejected for user '$u' → trying next credential..."
                # try next credential immediately (no sleep) within this attempt
                continue
            }

            if ($txt -match $connErr) {
                $sawConnErr = $true
                Write-Host "[SETBOOT][$Short] BMC/network not ready (connection error) → will sleep/retry..."
                # No point trying further credentials this attempt if BMC is unreachable
                break
            }
        }

        # If we reached here, no credential succeeded this attempt
        if ($sawConnErr) {
            Write-Host "[SETBOOT][$Short] Retrying in $SleepSeconds s due to connection readiness..."
        } else {
            Write-Host "[SETBOOT][$Short] All credentials failed this attempt → n$last"
            return "[Fail]  All credentials failed this attempt. Last output:`n$last"
        }
        Start-Sleep -Seconds $SleepSeconds
    }

    return "[Fail] set_onetime_boot retry exhausted ($MaxTries tries). Last output:`n$last"
}

function Mask-Creds {
    param([string]$s,[string]$user,[string]$pass)
    if (-not $s) { return $s }
    $s1 = ($s -replace [regex]::Escape($user), '*User*')
    $s2 = ($s1 -replace [regex]::Escape($pass), '*Pass*')
    return $s2
}

function Mask-AllCreds {
    param([string]$s, [System.Collections.IEnumerable]$creds)
    if (-not $s) { return $s }
    $masked = $s
    foreach ($c in $creds) {
        if ($c -and $c.user -and $c.pass) {
            $masked = Mask-Creds -s $masked -user $c.user -pass $c.pass
        }
    }
    return $masked
}

function Run-SSH {
    param(
        [Parameter(Mandatory)][string]$Target,   # e.g. "$global:linuxUser@host"
        [Parameter(Mandatory)][string]$Cmd,      # remote command string (no trailing RC echo)
        [string]$Tag = ""                        # for Write-Host context
    )
    # Append a return-code marker so we can always parse the exit code reliably
    $fullCmd = "$Cmd ; echo __RC:$?"
    $out = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t -o BatchMode=yes $Target $fullCmd
    $txt = ($out -join "`n")

    # Extract RC and strip marker from printed output
    $m = [regex]::Match($txt, '(?ms)__RC:(\d+)\s*$')
    $rc = if ($m.Success) { [int]$m.Groups[1].Value } else { -1 }
    $body = if ($m.Success) { $txt.Substring(0, $m.Index).TrimEnd() } else { $txt }

    return [pscustomobject]@{
        RC    = $rc
        Body  = $body
        Full  = $txt
        Tag   = $Tag
        Target= $Target
    }
}
function Invoke-PXErestartLegacy {
    param(
        [string[]]$Servers,
        [switch]$Pxe   # If present, also set one-time PXE Legacy before SUM
    )

    Write-Host "== Force Legacy Boot (Redfish → SUM → Redfish reboot) ==" -ForegroundColor Cyan

    # Infra endpoints / tools
    $remoteHost = $global:sshServer                # e.g. scyspnet04.sc.intel.com
    $remoteUser = $global:linuxUser
    $remote     = "$remoteUser@$remoteHost"
    $sumHost    = "scyspnet02.sc.intel.com"
    $sumRemote  = "$remoteUser@$sumHost"

    $rfPath     = "/nfs/site/gen/adm/linuxset/hardware/firmware/support_scripts/redfish_mgmt_utility/redfish_mgmt.py"
    $sumBin     = "~/work/sum-2.7"                 # fixed location per your note

    # Helpers
    function New-Log { New-Object System.Text.StringBuilder }
    function Add-Log([System.Text.StringBuilder]$sb, [string]$line) { [void]$sb.AppendLine($line) }
    function Mask-Creds([string]$s, [string]$u, [string]$p) {
        ($s -replace [regex]::Escape($u), '*User*') -replace [regex]::Escape($p), '*Pass*'
    }
    function Show-SshCmd([string]$Who, [string]$CmdMasked) {
        Write-Host "[SSH CMD][$Who] $CmdMasked" -ForegroundColor DarkCyan
    }

    # Sudo prime for Redfish
    if (-not $global:SudoPassword) {
        Write-Host "[ERROR] Missing global:SudoPassword." -ForegroundColor Red
        return @{ _global = "[Fail] Missing global:SudoPassword" }
    }
    Write-Host "[INIT] Priming sudo session on $remoteHost..."
    $prime = Start-RemoteSudoSession -Server $remoteHost -User $remoteUser -PlainPassword $global:SudoPassword -AllocateTty
    if ($prime.status -ne 'ok') {
        Write-Host "[ERROR] Sudo prime failed on ${remoteHost}: $($prime.output)" -ForegroundColor Red
        return @{ _global = "[Fail] Sudo prime failed on ${remoteHost}: $($prime.output)" }
    }
    Write-Host "[SUDO] Primed on $remoteHost for $remoteUser." -ForegroundColor Green

    # Load Redfish credentials
    $credsPath = Join-Path $PSScriptRoot "redfish_credentials.txt"
    if (-not (Test-Path $credsPath)) { throw "Missing credentials file: $credsPath" }
    $credentials = Get-Content $credsPath | ForEach-Object {
        if ($_ -match ',') { $p = $_.Split(','); [pscustomobject]@{ user=$p[0].Trim(); pass=$p[1].Trim() } }
    } | Where-Object { $_ -ne $null }

    $results = @{}

    foreach ($hostname in $Servers) {
        $short = ($hostname -split '\.')[0]
        $log = New-Log
        Write-Host "`n----- [$short] START -----" -ForegroundColor Yellow
        Add-Log $log "----- [$short] START -----"

        # STEP 1: mgmt IP
        Write-Host "[$short][STEP 1] Getting mgmt IP..."
        $mgmtCmd = "umatch nodes $short mgmt"
        $mgmtOut = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -q $remote $mgmtCmd 2>&1
        $mgmt = $mgmtOut | Select-String -Pattern '\d{1,3}(\.\d{1,3}){3}' | ForEach-Object { $_.Matches.Value } | Select-Object -First 1
        Add-Log $log "umatch: $mgmtOut"
        if (-not $mgmt) {
            Write-Host "[$short][ERROR] mgmt IP not found. Skipping." -ForegroundColor Red
            Add-Log $log "[ERROR] mgmt IP not found."
            $results[$short] = $log.ToString()
            Write-Host "----- [$short] END (NO MGMT) -----"
            continue
        }
        Write-Host "[$short] mgmt IP = $mgmt"
        Add-Log $log "mgmt=$mgmt"

        # STEP 2: Redfish set Legacy (+ optional PXE)
        Write-Host "[$short][STEP 2] Testing Redfish credentials and setting Legacy boot..."
        $userUsed = $null; $passUsed = $null; $rfOK = $false

        foreach ($cred in $credentials) {
            $u = $cred.user; $p = $cred.pass
 
            $cmd = "sudo $rfPath --set_onetime_boot 'Pxe' 'Legacy' -u $u -p $p -n $hostname"
            $cmdMasked = "sudo $rfPath --set_onetime_boot Pxe Legacy -u *User* -p *Pass* -n $hostname"
           

            Write-Host "[$short] Trying Redfish user '$u'..."
            Show-SshCmd $remote $cmdMasked
            Add-Log $log "Redfish cmd: $cmdMasked"
            $rfOut = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t -o BatchMode=yes $remote $cmd 2>&1
            $rfText = ($rfOut -join "`n") -replace '\x1B\[[0-9;]*[A-Za-z]', ''
            Write-Host "[$short][Redfish output]`n$rfOut"
            
            if ($rfText  -notmatch "Unable to create Redfish session|Status code:\s*401|403 Forbidden") {
                $userUsed = $u; $passUsed = $p; $rfOK = $true
                Write-Host "[$short] Redfish success with '$u'." -ForegroundColor Green
                Add-Log $log "Redfish OK with user=$u"
                break
            }
        }
        if (-not $rfOK) {
            Write-Host "[$short][ERROR] Redfish failed for all users." -ForegroundColor Red
            Add-Log $log "[ERROR] Redfish failed for all users."
            $results[$short] = $log.ToString()
            Write-Host "----- [$short] END (REDFISH AUTH FAIL) -----"
            continue
        }

        # STEP 2.5: Ensure SSH to SUM host
        Write-Host "[$short][STEP 2.5] Ensuring SSH access to $sumHost..."
        $sshCheck = Ensure-SshAccess -Server $sumHost -User $remoteUser
        if ($sshCheck.Status -ne "ok") {
            Write-Host "[$short][WARN] SSH access to $sumHost failed: $($sshCheck.Message) — skipping SUM." -ForegroundColor Yellow
            Add-Log $log "[WARN] Ensure-SshAccess failed: $($sshCheck.Message)"
            $sumPossible = $false
        } else {
            Write-Host "[$short][STEP 2.5][SSH] OK - Access verified." -ForegroundColor Green
            Add-Log $log "Ensure-SshAccess OK for $sumHost"
            $sumPossible = $true
        }
        # STEP 3: SUM (Dump → Detect → Edit via sed-file → Load)
        if ($sumPossible) {
            Write-Host "[$short][STEP 3] Running SUM (Dump → Detect → Edit → Load)..." -ForegroundColor Cyan
            $biosTmp = "/tmp/bios_${short}_$(Get-Random).xml"

            # 3.1 Dump
            $dumpCore = '$SUMBIN -i MGMT -u USER -p "PASS" -c GetCurrentBiosCfg --file FILE'
            $dumpCmd  = ("SUMBIN=" + $sumBin + " ; " + $dumpCore).
                Replace("MGMT",$mgmt).Replace("USER",$userUsed).Replace("PASS",$passUsed).Replace("FILE",$biosTmp)
            $dumpMasked = Mask-Creds $dumpCmd $userUsed $passUsed
            Write-Host "[$short][STEP 3.1] Dump BIOS → $biosTmp"
            Show-SshCmd $sumRemote $dumpMasked
            Add-Log $log "SUM Dump: $dumpMasked"
            $dumpOut = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t -o BatchMode=yes $sumRemote $dumpCmd 2>&1
            Write-Host "[$short][OUT]`n$dumpOut"
            Add-Log $log "SUM Dump OUT: $dumpOut"

            if ($dumpOut -match "<<<<<ERROR>>>>>") {
                Write-Host "[$short][WARN] SUM dump failed; will still reboot via Redfish." -ForegroundColor Yellow
                Add-Log $log "[WARN] SUM dump failed; skipping edit/load."
            } else {
                # 3.2 we already detect $fmt = "XML" or "TXT"; but the script can auto-detect
                # so we can just pass "auto".
                Write-Host "[$short][STEP 3.3] Editing BIOS via remote script ..." -ForegroundColor Cyan
                $biosEditCmd = "bash -lc '~/work/bios_sed.sh auto FILE'".Replace('FILE', $biosTmp)
                Write-Host "[SSH CMD][$sumRemote] $biosEditCmd" -ForegroundColor DarkCyan
                $biosEditOut = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t -o BatchMode=yes $sumRemote $biosEditCmd 2>&1
                Write-Host "[$short][OUT]`n$biosEditOut"

                # Optional: validate RC token
                if ($biosEditOut -notmatch "__SED_RC=0") {
                    Write-Host "[$short][WARN] bios_sed.sh returned non-zero; proceeding but SUM may not apply changes." -ForegroundColor Yellow
                }

                # 3.5 Load updated config
                $loadCore = '$SUMBIN -i MGMT -u USER -p "PASS" -c ChangeBiosCfg --file FILE --skip_unknown --skip_bbs'
                $loadCmd  = ("SUMBIN=" + $sumBin + " ; " + $loadCore).
                    Replace("MGMT",$mgmt).Replace("USER",$userUsed).Replace("PASS",$passUsed).Replace("FILE",$biosTmp)
                $loadMasked = Mask-Creds $loadCmd $userUsed $passUsed

                Write-Host "[$short][STEP 3.5] Loading BIOS..."
                Show-SshCmd $sumRemote $loadMasked
                Add-Log $log "SUM Load: $loadMasked"
                $loadOut = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t -o BatchMode=yes $sumRemote $loadCmd 2>&1
                Write-Host "[$short][OUT]`n$loadOut"
                Add-Log $log "SUM Load OUT: $loadOut"

                if ($loadOut -match "<<<<<ERROR>>>>>") {
                    Write-Host "[$short][WARN] SUM load failed; proceeding to reboot anyway." -ForegroundColor Yellow
                    Add-Log $log "[WARN] SUM load failed."
                } else {
                     Write-Host "[$short] SUM Legacy + (optional) CSM applied." -ForegroundColor Green
                    Add-Log $log "SUM applied OK."
                }
            }
        } else {
            Add-Log $log "SUM skipped (SSH to $sumHost failed)."
        }

        # STEP 4: Redfish reboot (always)
        $rbCmd = "sudo $rfPath --restart -u $userUsed -p $passUsed -m $mgmt"
        $rbMasked = Mask-Creds $rbCmd $userUsed $passUsed
        Write-Host "[$short][STEP 4] Rebooting via Redfish..."
        Show-SshCmd $remote $rbMasked
        Add-Log $log "Reboot cmd: $rbMasked"
        $rbOut = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t -o BatchMode=yes $remote $rbCmd 2>&1
        Write-Host "[$short][OUT]`n$rbOut"
        Add-Log $log "Reboot OUT: $rbOut"

        $results[$short] = $log.ToString()
        Write-Host "----- [$short] END (OK) -----"
    }

    return $results
}



function Invoke-AcCycleBlades {
    param([string[]]$Servers)
    Write-Host "== Action: AcCycleBlades =="

    $remoteHost = $global:sshServer
    $remote     = "$global:linuxUser@$remoteHost"

    # Prime sudo once
    if (-not $global:SudoPassword) {
        $m = "[Fail] Missing global:SudoPassword"
        $r = @{}; foreach ($h in $Servers) { $r[($h -split '\.')[0]] = $m }; return $r
    }
    $prime = Start-RemoteSudoSession -Server $remoteHost -User $global:linuxUser -PlainPassword $global:SudoPassword -AllocateTty
    if ($prime.status -ne 'ok') {
        $m = "[Fail] Sudo prime failed on ${remoteHost}: $($prime.output)"
        $r = @{}; foreach ($h in $Servers) { $r[($h -split '\.')[0]] = $m }; return $r
    }

    $credsPath = Join-Path $PSScriptRoot "redfish_credentials.txt"
    if (-not (Test-Path $credsPath)) { throw "Missing credentials file: $credsPath" }
    $credentials = Get-Content $credsPath | ForEach-Object { $p = $_.Split(","); [PSCustomObject]@{ user=$p[0].Trim(); pass=$p[1].Trim() } }

    $results = @{}
    foreach ($hostname in $Servers) {
        $short = ($hostname -split '\.')[0]
        Write-Host "[ACCYCLE] Processing $short"

        # --- Capture umatch command & output ---
        $umatchCmd = "umatch nodes $short enclosure bay"
        $umatch = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -q $remote $umatchCmd 2>&1
        if ($umatch -notmatch '^\s*(\S+)\s+(\d+)\s*$') { $results[$short] = "[Fail] umatch enclosure bay failed: $umatch"; continue }
        $cmm = $matches[1]; $blade = $matches[2]

        $final=""; $success=$false; $lastCmd=""; $lastOut=""
        foreach ($cred in $credentials) {
            $user=$cred.user; $pass=$cred.pass
            $cmd = "sudo /nfs/site/gen/adm/linuxset/hardware/firmware/support_scripts/redfish_mgmt_utility/redfish_mgmt.py --accycle_blade $blade -u $user -p $pass -m $cmm.sc.intel.com"
            Write-Host "[ACCYCLE] Run → $cmd"
            $out = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t -o BatchMode=yes $remote $cmd
            $txt = $out -join "`n"; $final=$txt
            $lastCmd = $cmd
            $lastOut = $txt
            if ($txt -notmatch "Unable to create Redfish session") { $success=$true; break }
        }

        if (-not $success) {
            $final = if ([string]::IsNullOrWhiteSpace($final)) { "[Fail] Redfish ac-cycle failed for all credentials" } else { "[Fail] $final" }
            $results[$short] = $final
            Write-Host "[ACCYCLE] Done $short"
            continue
        }

        # --- On success, append the remote commands & outputs ---
        $results[$short] = @"

$umatchCmd


$umatch


sudo /nfs/site/gen/adm/linuxset/hardware/firmware/support_scripts/redfish_mgmt_utility/redfish_mgmt.py --accycle_blade $blade -u *user* -p *pass* -m $cmm.sc.intel.com


$lastOut
"@

        Write-Host "[ACCYCLE] Done $short"
    }
    return $results
}



function Invoke-PowerOn {
    param([string[]]$Servers)
    Write-Host "== Action: PowerOn =="

    $remoteHost = $global:sshServer
    $remote     = "$global:linuxUser@$remoteHost"

    if (-not $global:SudoPassword) {
        $m = "[Fail] Missing global:SudoPassword"
        $r = @{}; foreach ($h in $Servers) { $r[($h -split '\.')[0]] = $m }; return $r
    }
    $prime = Start-RemoteSudoSession -Server $remoteHost -User $global:linuxUser -PlainPassword $global:SudoPassword -AllocateTty
    if ($prime.status -ne 'ok') { $m = "[Fail] Sudo prime failed on ${remoteHost}: $($prime.output)"; $r=@{}; foreach($h in $Servers){$r[($h -split '\.')[0]]=$m}; return $r }

    $credsPath = Join-Path $PSScriptRoot "redfish_credentials.txt"
    if (-not (Test-Path $credsPath)) { throw "Missing credentials file: $credsPath" }
    $credentials = Get-Content $credsPath | ForEach-Object { $p=$_.Split(","); [PSCustomObject]@{ user=$p[0].Trim(); pass=$p[1].Trim() } }

    $results=@{}
    foreach ($hostname in $Servers) {
        $short = ($hostname -split '\.')[0]


        
        # capture umatch command text and output
        $umatchCmd = "umatch nodes $short enclosure bay"
        $umatch = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -q $remote $umatchCmd 2>&1
        if ($umatch -notmatch '^\s*(\S+)\s+(\d+)\s*$') { $results[$short] = "[Fail] umatch enclosure bay failed: $umatch"; continue }
        $cmm=$matches[1]; $blade=$matches[2]

        Write-Host "[POWERON] Processing $short"

        $final=""; $success=$false; $lastCmd=""; $lastOut=""
        foreach ($cred in $credentials) {
            $user=$cred.user; $pass=$cred.pass
            $cmd = "sudo /nfs/site/gen/adm/linuxset/hardware/firmware/support_scripts/redfish_mgmt_utility/redfish_mgmt.py -n $short --power_on -u $user -p $pass "
            Write-Host "[POWERON] Run → $cmd"
            $out = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t -o BatchMode=yes $remote $cmd
            
            $cmd2 = "sudo /nfs/site/gen/adm/linuxset/hardware/firmware/support_scripts/redfish_mgmt_utility/redfish_mgmt.py --power_on_blade $blade -u $user -p $pass -m $cmm.sc.intel.com"
            Write-Host "[POWERON] Run → $cmd2"
            $out2 = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t -o BatchMode=yes $remote $cmd2


            $txt = $out -join "`n"; $final=$txt
            $lastCmd = $cmd
            $lastOut = $txt
            if ($txt -notmatch "Unable to create Redfish session") { $success=$true; break }
        }
        if (-not $success) {
            $final = if ([string]::IsNullOrWhiteSpace($final)) { "[Fail] Redfish power_on failed for all credentials" } else { "[Fail] $final" }
            $results[$short] = $final
            Write-Host "[POWERON] Done $short"
            continue
        }

        # Success: include raw remote commands + outputs (no numbering, no ssh wrapper)
        $results[$short] = @"


$umatchCmd
$umatch

sudo /nfs/site/gen/adm/linuxset/hardware/firmware/support_scripts/redfish_mgmt_utility/redfish_mgmt.py -n $short --power_on  -u *user* -p *pass*

"@

        Write-Host "[POWERON] Done $short"
    }
    return $results
}

function Invoke-LegacyReboot {
    param([string[]]$Servers)
    Write-Host "== Action: AcCycleBlades =="
    $remote    = "$global:linuxUser@$global:sshServer"

    $remoteHost = $global:sshServer
    $remote     = "$global:linuxUser@$remoteHost"

    if (-not $global:SudoPassword) {
        $m = "[Fail] Missing global:SudoPassword"
        $r = @{}; foreach ($h in $Servers) { $r[($h -split '\.')[0]] = $m }; return $r
    }
    $prime = Start-RemoteSudoSession -Server $remoteHost -User $global:linuxUser -PlainPassword $global:SudoPassword -AllocateTty
    if ($prime.status -ne 'ok') { $m = "[Fail] Sudo prime failed on ${remoteHost}: $($prime.output)"; $r=@{}; foreach($h in $Servers){$r[($h -split '\.')[0]]=$m}; return $r }

    $credsPath = Join-Path $PSScriptRoot "redfish_credentials.txt"
    if (-not (Test-Path $credsPath)) { throw "Missing credentials file: $credsPath" }

    $credentials = Get-Content $credsPath | ForEach-Object {
        $p = $_.Split(",")
        [PSCustomObject]@{ user = $p[0].Trim(); pass = $p[1].Trim() }
    }

    $results = @{}
    foreach ($hostname in $Servers) {
        $short = ($hostname -split '\.')[0]

        # Capture umatch command text and output
        $umatchCmd = "umatch nodes $short enclosure bay"
        $umatch = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -q $remote $umatchCmd 2>&1
        if ($umatch -notmatch '^\s*(\S+)\s+(\d+)\s*$') {
            $results[$short] = "[Fail] umatch enclosure bay failed: $umatch"; continue
        }
        $cmm = $matches[1]; $blade = $matches[2]


        $final = ""; $ok = $false
        $lastCmd = ""; $lastOut = ""
        $setBootCmd = ""; $setBootOut = ""
        foreach ($cred in $credentials) {
            $user = $cred.user; $pass = $cred.pass

            $cmd = "sudo /nfs/site/gen/adm/linuxset/hardware/firmware/support_scripts/redfish_mgmt_utility/redfish_mgmt.py -n $short --reboot -u $user -p $pass"
            Write-Host "[PXErestart] Run → $cmd"

            $out = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t -o BatchMode=yes $remote $cmd
            $txt = $out -join "`n"
            $final = $txt
            $lastCmd = $cmd
            $lastOut = $txt

            if ($txt -notmatch "Unable to create Redfish session") {
                $setBootCmd = "sleep 5; sudo  /nfs/site/gen/adm/linuxset/hardware/firmware/support_scripts/redfish_mgmt_utility/redfish_mgmt.py -n $short --set_onetime_boot 'Hdd' 'Legacy' -u $user -p $pass"
                Write-Host "[PXErestart] Set boot → $setBootCmd"
                # Execute set boot and capture output (does not affect control flow)
                $setBootOut = (ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t -o BatchMode=yes $remote $setBootCmd) -join "`n"
                $ok = $true
                break
            }
        }

        if ($ok) {
            # Include raw remote commands and outputs (no numbering, no ssh wrapper)
            $results[$short] = @"

$umatchCmd
$umatch

sudo /nfs/site/gen/adm/linuxset/hardware/firmware/support_scripts/redfish_mgmt_utility/redfish_mgmt.py -n $short --reboot -u *user* -p *pass*
$lastOut

"@
        } else {
            # Preserve original failure behavior/content
            $results[$short] = $final
        }

        Write-Host "[LegacyReboot] Done $short"
    }
    return $results
}


function Invoke-PXErestart {
    param([string[]]$Servers)
    Write-Host "== Action: PXErestart =="

    $remoteHost = $global:sshServer
    $remote     = "$global:linuxUser@$remoteHost"

    if (-not $global:SudoPassword) { $m="[Fail] Missing global:SudoPassword"; $r=@{}; foreach($h in $Servers){$r[($h -split '\.')[0]]=$m}; return $r }
    $prime = Start-RemoteSudoSession -Server $remoteHost -User $global:linuxUser -PlainPassword $global:SudoPassword -AllocateTty
    if ($prime.status -ne 'ok') { $m="[Fail] Sudo prime failed on ${remoteHost}: $($prime.output)"; $r=@{}; foreach($h in $Servers){$r[($h -split '\.')[0]]=$m}; return $r }

    $credsPath = Join-Path $PSScriptRoot "redfish_credentials.txt"
    if (-not (Test-Path $credsPath)) { throw "Missing credentials file: $credsPath" }
    $credentials = Get-Content $credsPath | ForEach-Object { $p=$_.Split(","); [PSCustomObject]@{ user=$p[0].Trim(); pass=$p[1].Trim() } }

    $results=@{}
    foreach ($hostname in $Servers) {
        $short = ($hostname -split '\.')[0]
        Write-Host "[PXErestart] Processing $short"

        # capture umatch command text and output
        $umatchCmd = "umatch nodes $short enclosure bay"
        $umatch = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -q $remote $umatchCmd 2>&1
        if ($umatch -notmatch '^\s*(\S+)\s+(\d+)\s*$') { $results[$short] = "[Fail] umatch enclosure bay failed: $umatch"; continue }
        $cmm=$matches[1]; $blade=$matches[2]


        $final=""; $success=$false; $userUsed=$null; $passUsed=$null
        $lastCmd=""; $lastOut=""
        foreach ($cred in $credentials) {
            $user=$cred.user; $pass=$cred.pass
            $cmd = "sudo /nfs/site/gen/adm/linuxset/hardware/firmware/support_scripts/redfish_mgmt_utility/redfish_mgmt.py --set_onetime_boot 'Pxe' 'UEFI' -u $user -p $pass -n $hostname ;sudo /nfs/site/gen/adm/linuxset/hardware/firmware/support_scripts/redfish_mgmt_utility/redfish_mgmt.py --restart -u $user -p $pass -n $hostname"
            Write-Host "[PXErestart] AC cycle → $cmd"
            $out = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t -o BatchMode=yes $remote $cmd
            $txt = $out -join "`n"; $final=$txt
            $lastCmd = $cmd
            $lastOut = $txt
            if ($txt -notmatch "Unable to create Redfish session") { $success=$true; $userUsed=$user; $passUsed=$pass; break }
        }
        if (-not $success) {
            $results[$short] = if ([string]::IsNullOrWhiteSpace($final)) { "[Fail] Redfish ac-cycle failed for all credentials" } else { "[Fail] $final" }
            continue
        }

        # After AC cycle, set one-time boot (PXE Legacy) with retry
        #$setRes = Invoke-SetOneTimeBootWithRetry -Remote $remote -hostname $hostname -User $userUsed -Pass $passUsed

        # success output: include raw remote commands + outputs (no ssh wrapper)
        $results[$short] = @"

$umatchCmd
$umatch
sudo /nfs/site/gen/adm/linuxset/hardware/firmware/support_scripts/redfish_mgmt_utility/redfish_mgmt.py --set_onetime_boot 'Pxe' 'Legacy' -u *user* -p *pass* -n $hostname 

sudo /nfs/site/gen/adm/linuxset/hardware/firmware/support_scripts/redfish_mgmt_utility/redfish_mgmt.py --restart -u *user*  -p *pass* -n $hostname

$lastOut

"@

        Write-Host "[PXErestart] Done $short"
    }
    return $results
}

function Invoke-BMCrestart {
    param([string[]]$Servers)
    Write-Host "== Action: BMCrestart =="

    $remoteHost = $global:sshServer
    $remote     = "$global:linuxUser@$remoteHost"

    if (-not $global:SudoPassword) { $m="[Fail] Missing global:SudoPassword"; $r=@{}; foreach($h in $Servers){$r[($h -split '\.')[0]]=$m}; return $r }
    $prime = Start-RemoteSudoSession -Server $remoteHost -User $global:linuxUser -PlainPassword $global:SudoPassword -AllocateTty
    if ($prime.status -ne 'ok') { $m="[Fail] Sudo prime failed on ${remoteHost}: $($prime.output)"; $r=@{}; foreach($h in $Servers){$r[($h -split '\.')[0]]=$m}; return $r }

    $credsPath = Join-Path $PSScriptRoot "redfish_credentials.txt"
    if (-not (Test-Path $credsPath)) { throw "Missing credentials file: $credsPath" }
    $credentials = Get-Content $credsPath | ForEach-Object { $p=$_.Split(","); [PSCustomObject]@{ user=$p[0].Trim(); pass=$p[1].Trim() } }

    $results=@{}
    foreach ($hostname in $Servers) {
        $short = ($hostname -split '\.')[0]

        $final=""; $success=$false
        $lastCmd=""; $lastOut=""
        foreach ($cred in $credentials) {
            $user=$cred.user; $pass=$cred.pass
            $cmd = "sudo  /nfs/site/gen/adm/linuxset/hardware/firmware/support_scripts/redfish_mgmt_utility/redfish_mgmt.py -n $short --reset_bmc -u $user -p $pass"
            Write-Host "[BMCrestart] Run → $cmd"
            $out = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t -o BatchMode=yes $remote $cmd
            $txt = $out -join "`n"; $final=$txt
            $lastCmd = $cmd
            $lastOut = $txt
            if ($txt -notmatch "Unable to create Redfish session") { $success=$true; break }
        }

        if (-not $success) {
            $final = if ([string]::IsNullOrWhiteSpace($final)) { "Redfish BMC reset failed for all credentials" } else { "$final" }
            $results[$short]=$final
            Write-Host "[BMCrestart] Done $short"
            continue
        }
        $connErr = '(?is)HTTPSConnectionPool|Max\s+retries\s+exceeded|Failed\s+to\s+establish\s+a\s+new\s+connection'
        if ($txt -match $connErr) {
            $final = "[Fail] Failed connection to bmc"
            $results[$short]=$final
            Write-Host "[BMCrestart] Fail $short"
            continue
        }
        # Success: include raw remote command + output (no ssh wrapper)
        $results[$short] = @"


sudo  /nfs/site/gen/adm/linuxset/hardware/firmware/support_scripts/redfish_mgmt_utility/redfish_mgmt.py -n $short --reset_bmc -u *user* -p *pass*

"@

        Write-Host "[BMCrestart] Done $short"
    }
    return $results
}
function Invoke-Restart  {
    param([string[]]$Servers)
    Write-Host "== Action: Restart =="

    $remoteHost = $global:sshServer
    $remote     = "$global:linuxUser@$remoteHost"

    if (-not $global:SudoPassword) { $m="[Fail] Missing global:SudoPassword"; $r=@{}; foreach($h in $Servers){$r[($h -split '\.')[0]]=$m}; return $r }
    $prime = Start-RemoteSudoSession -Server $remoteHost -User $global:linuxUser -PlainPassword $global:SudoPassword -AllocateTty
    if ($prime.status -ne 'ok') { $m="[Fail] Sudo prime failed on ${remoteHost}: $($prime.output)"; $r=@{}; foreach($h in $Servers){$r[($h -split '\.')[0]]=$m}; return $r }

    $credsPath = Join-Path $PSScriptRoot "redfish_credentials.txt"
    if (-not (Test-Path $credsPath)) { throw "Missing credentials file: $credsPath" }
    $credentials = Get-Content $credsPath | ForEach-Object { $p=$_.Split(","); [PSCustomObject]@{ user=$p[0].Trim(); pass=$p[1].Trim() } }

    $results=@{}
    foreach ($hostname in $Servers) {
        $short = ($hostname -split '\.')[0]

        $final=""; $success=$false
        foreach ($cred in $credentials) {
            $user=$cred.user; $pass=$cred.pass
            $cmd = "sudo  /nfs/site/gen/adm/linuxset/hardware/firmware/support_scripts/redfish_mgmt_utility/redfish_mgmt.py -n $short --restart -u $user -p $pass"
            Write-Host "[Restart] Run â†’ $cmd"
            $out = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t -o BatchMode=yes $remote $cmd
            $txt = $out -join "`n"; $final=$txt
            if ($txt -notmatch "Unable to create Redfish session") { $success=$true; break }
        }
        if (-not $success) { $final = if ([string]::IsNullOrWhiteSpace($final)) { "[Fail] Redfish restart failed for all credentials" } else { "[Fail] $final" } }
        $results[$short]=$final
        Write-Host "[Restart] Done $short"
    }
    return $results
}


function Invoke-Reboot {
    param([string[]]$Servers)
    Write-Host "== Action: Reboot =="

    $remote    = "$global:linuxUser@$global:sshServer"
    $remoteHost = $global:sshServer

    if (-not $global:SudoPassword) { $m="[Fail] Missing global:SudoPassword"; $r=@{}; foreach($h in $Servers){$r[($h -split '\.')[0]]=$m}; return $r }
    $prime = Start-RemoteSudoSession -Server $remoteHost -User $global:linuxUser -PlainPassword $global:SudoPassword -AllocateTty
    if ($prime.status -ne 'ok') { $m="[Fail] Sudo prime failed on ${remoteHost}: $($prime.output)"; $r=@{}; foreach($h in $Servers){$r[($h -split '\.')[0]]=$m}; return $r }


    $credsPath = Join-Path $PSScriptRoot "redfish_credentials.txt"
    if (-not (Test-Path $credsPath)) { throw "Missing credentials file: $credsPath" }

    # Load Redfish/BMC credentials
    $credentials = Get-Content $credsPath | ForEach-Object {
        $p = $_.Split(",")
        [PSCustomObject]@{ user = $p[0].Trim(); pass = $p[1].Trim() }
    }

    $results = @{}

    foreach ($hostname in $Servers) {
        $short = ($hostname -split '\.')[0]
        Write-Host "[REBOOT] Processing $short"

        # Resolve BMC mgmt IP (for SOL)
        $mgmtIP = $null
        $umatchIP = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -q $remote "umatch nodes $short mgmt" 2>&1
        if ($umatchIP -match '^\s*(\d+\.\d+\.\d+\.\d+)\s*$') {
            $mgmtIP = $matches[1]
            Write-Host "[REBOOT] mgmt IP: $mgmtIP"
        } else {
            Write-Host "[REBOOT][WARN] umatch mgmt failed for $short â†’ $umatchIP"
        }

        $final = ""
        foreach ($cred in $credentials) {
            $user = $cred.user; $pass = $cred.pass

            # Redfish reboot (one-liner)
            $cmd = "sudo /nfs/site/gen/adm/linuxset/hardware/firmware/support_scripts/redfish_mgmt_utility/redfish_mgmt.py -n $short --reboot -u $user -p $pass"
            Write-Host "[REBOOT] Run â†’ $cmd"
            $out = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t -o BatchMode=yes $remote $cmd
            $txt = $out -join "`n"
            $final = $txt

            if ($txt -notmatch "Unable to create Redfish session") {
                Write-Host "[REBOOT] Redfish reboot accepted with user '$user'"

                # If we have a mgmt IP, start detached SOL capture with SAME creds (one-liner)
                if ($mgmtIP) {
                    # After successful Redfish reboot:
                    $null = Start-LocalSolCapture -HostShort $short -MgmtIP $mgmtIP -User $user -Pass $pass
                } else {
                    Write-Host "[REBOOT][SOL] Skipped (no mgmt IP available)."
                }
   
                break
            } else {
                Write-Host "[REBOOT][WARN] Redfish login failed with user '$user' â†’ trying next credential"
            }
        }

        $results[$short] = $final
        Write-Host "[REBOOT] Done $short"
    }

    return $results
}

function Invoke-FixCobbler {
    param([string[]]$Servers)
    Write-Host "== Action: FixCobbler =="
    $remote  = "$global:linuxUser@$global:cobblerServer"
    $remoteHost = $global:cobblerServer
    if (-not $global:SudoPassword) { $m="[Fail] Missing global:SudoPassword"; $r=@{}; foreach($h in $Servers){$r[($h -split '\.')[0]]=$m}; return $r }
    $prime = Start-RemoteSudoSession -Server $global:cobblerServer -User $global:linuxUser -PlainPassword $global:SudoPassword -AllocateTty
    if ($prime.status -ne 'ok') { $m="[Fail] Sudo prime failed on ${remoteHost}: $($prime.output)"; $r=@{}; foreach($h in $Servers){$r[($h -split '\.')[0]]=$m}; return $r }
    $results = @{}
    foreach ($h in $Servers) {
        $short = ($h -split '\.')[0]
        Write-Host "[COBBLER] Processing $short"
        # 1) Get dnsdomain + mac
        $umatchCmd = "umatch nodes $short dnsdomain macaddr"
        Write-Host "umatch nodes $short dnsdomain macaddr"
        $umatchOut = (& ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -q $remote $umatchCmd  2>&1) -join "`n"
        Write-Host "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -q $remote $umatchCmd"
        Write-Host  $umatchOut
        if ($umatchOut -notmatch '([a-z0-9\.-]+\.intel\.com)\s+([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})') {
            Write-Host "[COBBLER][WARN] umatch failed for $short"
            Write-Host "[COBBLER][WARN] umatch failed $umatchOut"
            $results[$short] = "[Fail] umatch failed: $umatchOut"
            continue
        }
        $dnsDomain = $matches[1].Trim()
        $macAddr   = $matches[2].Trim()
        $fqdn      = "$short.$dnsDomain"
        Write-Host "[COBBLER] fqdn=$fqdn  mac=$macAddr"
        # 2) Determine which cobbler name exists: short or fqdn
        $reportShortCmd = "cobbler system report --name $short"
        $reportShort    = (& ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -q $remote $reportShortCmd 2>&1) -join "`n"
        $useName       = $short
        $reportUsed    = $reportShort
        $reportUsedCmd = $reportShortCmd
        if ($reportShort -match '(?i)\bNo system found\b') {
            Write-Host "[COBBLER] '$short' not found, trying FQDN…"
            $reportFqdnCmd = "cobbler system report --name $fqdn"
            $reportFqdn    = (ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -q $remote $reportFqdnCmd 2>&1) -join "`n"
            if ($reportFqdn -match '(?i)\bNo system found\b') {
                Write-Host "[COBBLER][Fail] No Cobbler system for '$short' or '$fqdn'"
                $results[$short] = @"
[Fail] No matching Cobbler system found with either '$short' or '$fqdn'.
"@
                continue
            } else {
                $useName       = $fqdn
                $reportUsed    = $reportFqdn
                $reportUsedCmd = $reportFqdnCmd
            }
        }
        Write-Host "[COBBLER] Using system name: $useName"
        # 3) Apply edits with the chosen name
        $editMeta = "sudo cobbler system edit --name $useName --autoinstall-meta `'`'"
        $editMac  = "sudo cobbler system edit --name $useName --mac-address $macAddr"
        
        Write-Host "[COBBLER] Run → $editMeta"
        $rMeta = (ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t $remote $editMeta) -join "`n"
        Write-Host "[COBBLER] Run → $editMac"
        $rMac  = (ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t $remote $editMac ) -join "`n"
        

        # 3.5) Optional rename from short -> FQDN (only if we matched SHORT and domain != sc.intel.com)
        $renameCmd  = $null
        $rRename    = $null
        $ReportCmd = $null
        $ReportOut = $null
        if ($useName -eq $short -and $dnsDomain -ne 'sc.intel.com') {
            $renameCmd = "sudo cobbler system rename --name=$short --newname=$fqdn --hostname=$fqdn"
            Write-Host "[COBBLER] Rename short → FQDN (domain=$dnsDomain) → $renameCmd"
            $rRename = (ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t $remote $renameCmd) -join "`n"
            $ReportCmd = "cobbler system report --name $fqdn"
            $ReportOut = (ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t $remote $ReportCmd  ) -join "`n"
        }else {
        
            $ReportCmd = "cobbler system report --name $useName "
            $ReportOut = (ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -t $remote $ReportCmd  ) -join "`n"
        }

    # 4) Consolidated per-host output
    if ([string]::IsNullOrEmpty($renameCmd)) {
        $renameSection = ""
    } else {
        $renameSection = "$renameCmd`n$rRename"
    }

    $results[$short] = @"

$editMeta
$rMeta
$editMac
$rMac

$renameSection

$ReportCmd
$ReportOut

"@

        Write-Host "[COBBLER] Done $short"
    }
    return $results
}

# ===== POST /run-allquery (unchanged) =====
function Invoke-RunAllQueryText {
    param([Parameter(Mandatory)][string[]]$Hosts)

    $shorts = $Hosts | ForEach-Object { ($_ -split '\.')[0].ToLower() }
    $hostList = ($shorts -join ' ')
    Write-Host "[ALLQUERY] Running for: $hostList"

    $remote = "$global:linuxUser@$global:sshServer"
    $cmd    = "/nfs/site/disks/hpcfeme/hme_sync/scripts/linux_query/allquery.py $hostList"
    $raw    = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o UpdateHostKeys=no -q $remote $cmd 2>&1
    Write-Host "[ALLQUERY] Received $($raw.Count) line(s)"

    # Stop before "Downadmin Summary"
    $clean = @()
    foreach ($line in $raw) { if ($line -match "^Downadmin Summary:") { break }; $clean += $line }

    # Split sections and group by host
    $sections = @{}
    $current = ""; $buf = @()
    foreach ($line in $clean) {
        if ($line -match "^(Node Fields 1:|Node Fields 2:|System Summary:)") {
            if ($current) { $sections[$current] = $buf }
            $current = $line.TrimEnd(":"); $buf = @($line)
        } else { $buf += $line }
    }
    if ($current -and $buf.Count) { $sections[$current] = $buf }

    $perHost = @{}
    foreach ($section in $sections.Keys) {
        $lines = $sections[$section]
        $headerIndex = ($lines | Select-String -Pattern '^\|.*\|.*\|' | Select-Object -First 1).LineNumber
        if (-not $headerIndex) { continue }
        $header = $lines[$headerIndex - 1]
        for ($i = $headerIndex; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -notmatch '^\|\s*\d+\s*\|') { continue }
            if ($line -match '^\|\s*\d+\s*\|\s*([^\s|]+)') {
                $fullHost  = $matches[1]
                $shortHost = ($fullHost -split '\.')[0].ToLower()
                if (-not $perHost.ContainsKey($shortHost)) { $perHost[$shortHost] = "" }
                $perHost[$shortHost] += "${section}:`n$header`n$line`n`n"
            }
        }
    }
    Write-Host "[ALLQUERY] Grouped results for $($perHost.Count) host(s)"
    return $perHost
}

# ===== POST /pxe-restart =====
function Handle-PXErestart {
    param (
        [System.Net.HttpListenerRequest]  $Request,
        [System.Net.HttpListenerResponse] $Response
    )

    Write-Host "`n==== POST /pxe-restart ===="

    # Parse and validate body
    $body = Get-JsonBody -Request $Request
    if (-not $body -or -not $body.servers -or $body.servers.Count -eq 0) {
        Write-Host "[PXErestart][ERROR] Missing or invalid 'servers' list"
        $Response.StatusCode = 400
        return Write-OutputToResponse $Response (
            @{ status = "error"; message = "[Fail] Missing or invalid 'servers' list" } | ConvertTo-Json -Compress
        )
    }

    # Normalize to short hostnames (keep your prior convention)
    $servers = @($body.servers | ForEach-Object { ($_ -split '\.')[0].Trim() } | Where-Object { $_ -ne "" })
    Write-Host "[PXErestart] Servers received: $($servers -join ', ')"

    try {
        # Execute core action
        $results = Invoke-PXErestart -Servers $servers
        Write-Host "[PXErestart] Completed for $($results.Keys.Count) host(s)"

        $Response.StatusCode = 200
        $payload = @{ status = "ok"; results = $results } | ConvertTo-Json -Depth 10 -Compress
        return Write-OutputToResponse $Response $payload
    } catch {
        $msg = "[Fail] Invoke-PXErestart exception: $($_.Exception.Message)"
        Write-Host "[PXErestart][EXCEPTION] $msg"
        $Response.StatusCode = 500
        return Write-OutputToResponse $Response (
            @{ status = "error"; message = $msg } | ConvertTo-Json -Compress
        )
    }
}

function Handle-ResolutionAutomation {
    param (
        [System.Net.HttpListenerRequest] $Request,
        [System.Net.HttpListenerResponse] $Response, 
        [bool] $Rebuild
    )

    Write-Host "`n==== POST /resolution-automation ===="
    $body = Get-JsonBody -Request $Request
    if (-not $body -or -not $body.servers -or $body.servers.Count -eq 0) {
        $Response.StatusCode = 400
        return Write-OutputToResponse $Response (@{ status="error"; message="Missing or invalid 'servers' list" } | ConvertTo-Json -Compress)
    }

    $hosts = @($body.servers | ForEach-Object { ($_ -split '\.')[0].ToLower() })
    Write-Host "[RES-AUTO] Hosts: $($hosts -join ', ')"

    # 0) allquery for all hosts up-front
    $aqByHost = @{}
    try { $aqByHost = Invoke-RunAllQueryText -Hosts $hosts } catch { Write-Host "[RES-AUTO][WARN] allquery failed: $($_.Exception.Message)" }
    $onlineRegex  = '(?m)^\|\s*\d+\s*\|\s*\S+\s*\|\s*Online\s*\|'
    $offlineRegex = '(?m)^\|\s*\d+\s*\|\s*\S+\s*\|\s*Offline\s*\|'

    $results = @{}

    foreach ($short in $hosts) {
        Write-Host "`n[RES-AUTO] -------------------------------------------"
        Write-Host "[RES-AUTO] Host: $short"
        try {
            $rec = Load-HostRecord -HostShort $short

            # 1) Persist allquery + Online/Offline/Unknown
            $aqText = if ($aqByHost.ContainsKey($short)) { [string]$aqByHost[$short] } else { "" }
            $rec['AllQueryResult'] = $aqText
            if     ($aqText -match $onlineRegex)  { $rec['Online'] = 'Online' }
            elseif ($aqText -match $offlineRegex) { $rec['Online'] = 'Offline' }
            else                                  { $rec['Online'] = 'Unknown' }
            Write-Host "[RES-AUTO] allquery → $($rec['Online'])"

            # 2) Skip if Online
            if ($rec['Online'] -eq 'Online') {
                Save-HostRecord -HostShort $short -Record $rec
                $results[$short] = @{ skipReason="Online via allquery"; actionsTaken=@(); outputs=@{}; fileRecord=$rec }
                continue
            }

            # 3) Skip if a step ran recently (based on LastResolution.Time)
            $gate = Should-SkipByLastResolution -Record $rec -Minutes 10
            if ($gate.Skip) {
                Write-Host "[RES-AUTO] Skipping ($($gate.Reason))."
                Save-HostRecord -HostShort $short -Record $rec
                $results[$short] = @{ skipReason=$gate.Reason; actionsTaken=@(); outputs=@{}; fileRecord=$rec }
                continue
            }

            # 4) Pause if last step failed (no escalation)
            #if (Last-Step-Failed -Record $rec) {
            #    Write-Host "[RES-AUTO] Skipping (last step failed; pause escalation)."
            #    Save-HostRecord -HostShort $short -Record $rec
            #    $results[$short] = @{ skipReason="Last step failed"; actionsTaken=@(); outputs=@{}; fileRecord=$rec }
            #    continue
            #}

            # 5) Decide exactly ONE next step in sequence
            $nextAction = Next-Sequential-Step -Record $rec
         
            if (-not $nextAction) {
                Write-Host "[RES-AUTO] No remaining steps."
                Save-HostRecord -HostShort $short -Record $rec
                $results[$short] = @{ skipReason="All steps completed"; actionsTaken=@(); outputs=@{}; fileRecord=$rec }
                continue
            }
            if ($Rebuild) { 
                $nextAction = Next-Sequential-Step-Rebuild -Record $rec
                if (-not $nextAction) {
                    Write-Host "[RES-AUTO] No remaining steps."
                    Save-HostRecord -HostShort $short -Record $rec
                    $results[$short] = @{ skipReason="All steps completed"; actionsTaken=@(); outputs=@{}; fileRecord=$rec }
                    continue
                }

            }

            Write-Host "[RES-AUTO] Next step → $nextAction"

            # >>> SKIP BRANCH: record as Success in file, include skipReason in response
            $userSkipReason = $null
            if ($global:SkipSteps -and $global:SkipSteps.ContainsKey($nextAction)) {
                $userSkipReason = [string]$global:SkipSteps[$nextAction]
            }
            if ($userSkipReason) {
                Write-Host "[RES-AUTO] Step '$nextAction' is SKIPPED by user. Reason: $userSkipReason"
                Add-ResolutionStep -Record $rec -ActionName $nextAction -Status 'Success' -Note ("Skipped by user: " + $userSkipReason)
                Save-HostRecord -HostShort $short -Record $rec
                $results[$short] = @{
                    actionsTaken = @($nextAction)                 # counts as completed for sequencing
                    skipReason   = $userSkipReason                # <-- expose to frontend
                    outputs      = @{$nextAction = "skipped"}     # optional extra signal
                    fileRecord   = $rec
                }
                continue  # one step per call
            }
            # <<< END SKIP BRANCH

            $outputs = @{}
            $outText = ""

            # 5a) If this is NOT Reboot, first stop & harvest SOL (boot log) and save to record
            #if ($nextAction -ne 'Reboot') {
            #    try {
            #        $harv = Stop-LocalSolCaptureAndFetch -HostShort $short
            #        $rec.IloAfterRebootOutput = [string]$harv.text
            #        Save-HostRecord -HostShort $short -Record $rec
            #        $outputs['IloBootLogCaptured'] = ($rec.IloAfterRebootOutput.Length)
            #    } catch {
            #        Write-Host "[SOL][LOCAL][WARN] Harvest failed for ${short}: $($_.Exception.Message)"
            #        $outputs['IloBootLogCaptured'] = "error: $($_.Exception.Message)"
            #    }
            #}

            # 6) Execute ONE action
            switch ($nextAction) {
                'PowerOn'      { $tmp = Invoke-PowerOn        -Servers @($short); $outText = $tmp[$short]; $outputs[$nextAction] = $outText }
                'AcCycle'      { $tmp = Invoke-AcCycleBlades  -Servers @($short); $outText = $tmp[$short]; $outputs[$nextAction] = $outText }
                'PressKey'     { $tmp = Invoke-WorkaroundLogin -Servers @($short); $outText = $tmp[$short]; $outputs[$nextAction] = $outText }
                'Reboot'       { $tmp = Invoke-LegacyReboot   -Servers @($short); $outText = $tmp[$short]; $outputs[$nextAction] = $outText }
                'BmcReset'     { $tmp = Invoke-BMCrestart     -Servers @($short); $outText = $tmp[$short]; $outputs[$nextAction] = $outText }
                'LegacyReboot' { $tmp = Invoke-LegacyReboot   -Servers @($short); $outText = $tmp[$short]; $outputs[$nextAction] = $outText }
                'CobblerCheck' { $tmp = Invoke-FixCobbler     -Servers @($short); $outText = $tmp[$short]; $outputs[$nextAction] = $outText }
                'PxeReset2'     { $tmp = Invoke-PXErestartLegacy     -Servers @($short); $outText = $tmp[$short]; $outputs[$nextAction] = $outText }
                'PxeReset1'     { $tmp = Invoke-PXErestart     -Servers @($short); $outText = $tmp[$short]; $outputs[$nextAction] = $outText }
                default        { $outputs[$nextAction] = "Unknown action"; $outText = "" }
            }

            # 7) Success/Fail flag + record step
            $ok = Test-ActionSuccess -Output ([string]$outText)
            $status = if ($ok) { 'Success' } else { 'Fail' }
            Add-ResolutionStep -Record $rec -ActionName $nextAction -Status $status

            # 8) Persist and respond
            Save-HostRecord -HostShort $short -Record $rec
            $results[$short] = @{ actionsTaken=@($nextAction); outputs=$outputs; fileRecord=$rec }
        }
        catch {
            Write-Host "[RES-AUTO][Fail] $short → $($_.Exception.Message)"
            $results[$short] = @{ actionsTaken=@(); outputs=@{ error="$($_.Exception.Message)" }; fileRecord=$null }
        }
    }

    $Response.StatusCode = 200
    $payload = @{ status="ok"; results=$results } | ConvertTo-Json -Depth 10 -Compress
    return Write-OutputToResponse $Response $payload
}
# ===== Router (ONLY TWO POST ENDPOINTS) =====
function Handle-Request {
    param ([System.Net.HttpListenerContext] $Context)
    $request  = $Context.Request
    $response = $Context.Response
    $method   = $request.HttpMethod.ToUpper()
    $path     = $request.Url.AbsolutePath.ToLower()
    $routeKey = "$method $path"

    switch ($routeKey) {
        "GET /ping"                   { $response.StatusCode = 200; Write-OutputToResponse $response "Listener OK" }
        "POST /init"            { Handle-InitRequest -Request $request -Response $response }
        "POST /send-ssh-key"    { Handle-SendSshKey -Response $response }
        "POST /run-allquery"          { Handle-RunAllQuery -Request $request -Response $response }
        "POST /resolution-automation" { Handle-ResolutionAutomation -Request $request -Response $response -Rebuild $False}
        "POST /pxe-restart" { Handle-ResolutionAutomation -Request $request -Response $response -Rebuild  $True }
        "POST /stop" {
            Write-Host "POST /stop"
            $global:shutdown = $true
            $response.StatusCode = 200
            Write-OutputToResponse $response "Shutting down"
        }
        default {
            if ($method -eq "OPTIONS") {
                $response.StatusCode = 204
                $response.AddHeader("Access-Control-Allow-Origin", "*")
                $response.AddHeader("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
                $response.AddHeader("Access-Control-Allow-Headers", "Content-Type")
                $response.Close()
            } else {
                $response.StatusCode = 404
                Write-OutputToResponse $response "Endpoint not found"
            }
        }
    }
}

function Start-LocalListener {
    [CmdletBinding()]
    param(
        [int] $BasePort = 8081,  # first port to try
        [int] $Range    = 10     # how many ports to scan (8081..8090)
    )

    Write-Host "`nStarting listener`n" -ForegroundColor Cyan

    $listener = $null
    $chosen   = $null

    for ($i = 0; $i -lt $Range; $i++) {
        $port   = $BasePort + $i
        $prefix = "http://+:$port/"

        try {
            $listener = [System.Net.HttpListener]::new()
            $listener.Prefixes.Add($prefix)
            $listener.AuthenticationSchemes = [System.Net.AuthenticationSchemes]::Anonymous
            $listener.IgnoreWriteExceptions = $true
            $listener.Start()
            $chosen = $port
            Write-Host "Listening on $prefix"
            break
        } catch {
            if ($listener) { try { $listener.Close() } catch {} }
            Write-Warning "Port $port unavailable: $($_.Exception.Message)"
            $listener = $null
            continue
        }
    }

    if (-not $listener) {
        throw "Failed to start listener: no free port in $BasePort..$([int]($BasePort+$Range-1)))."
    }

    # Expose chosen port so UI/frontend can display it
    $global:ListenerPort = $chosen

    try {
        while ($listener.IsListening -and -not $global:shutdown) {
            try {
                $context = $listener.GetContext()   # blocks
            } catch {
                if (-not $listener.IsListening) { break }
                Write-Warning "GetContext() error: $($_.Exception.Message)"
                continue
            }

            try {
                Handle-Request -Context $context
            } catch {
                try {
                    $context.Response.StatusCode = 500
                    $bytes = [Text.Encoding]::UTF8.GetBytes("Internal Server Error")
                    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $context.Response.Close()
                } catch { }
                Write-Warning "Handler error: $($_.Exception.Message)"
            }
        }
    } finally {
        if ($listener.IsListening) { $listener.Stop() }
        $listener.Close()
        Write-Host "Listener stopped."
    }
}



# Ensure extension policies exist (Edge only)

$skipAns = (Read-Host "Do you you want to run Tampermonkey setup (y/N)").Trim()
if ($skipAns -match '^(?i:y|yes)$') {
    Ensure-TampermonkeyInstalled -Browsers Edge -RestartBrowsers
    Show-EdgeDevModeInstructions
    Prompt-InstallCMDBUserScript
}


# ===== Execution =====
Stop-SshAtStartup  -Aggressive          # safe mode
# Stop-SshAtStartup -Aggressive  # nuke all ssh/plink
Enable-KeepAwakeForSession

# Prune host records ≥ 10 days old
$cleanup = Remove-OldHostFiles -Days 10
Write-Host "[CLEANUP] Summary → Deleted=$($cleanup.deleted); Errors=$(@($cleanup.errors).Count)"


Sshkeydist -Server sc-login.sc.intel.com -User $global:linuxUser
Read-RemoteSudoPassword | Out-Null 

# set the default order and skip nothing
Initialize-ResolutionPlan


Start-Process "https://intel.service-now.com/now/nav/ui/classic/params/target/incident_list.do%3Fsysparm_query%3Dassignment_group%253D23b9b06d1b579010bcb7326edc4bcb25%255Estate%253D1%255Eshort_descriptionLIKEAutoOps%255EORshort_descriptionLIKESRT%255Eshort_descriptionNOT%2520LIKE%255BOnline%255D%255Eshort_descriptionNOT%2520LIKE%255BOffline%255D%26sysparm_first_row%3D1%26sysparm_view%3D&sysparm_forceClassic=true"

# ===== RUN =====
Start-LocalListener

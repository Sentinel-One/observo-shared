# Observo Edge Uninstall Script for Windows
#
# -KeepConfig is the single knob:
#   absent -> remove EVERYTHING the agent installed (binaries, config,
#             install dir, logs, update dir).
#   present -> remove everything EXCEPT edge-config.json, which is left in
#              place inside the install dir.
param (
    [switch]$KeepConfig
)

# This uninstaller cleans up BOTH the legacy ("old") agent layout and the
# current ("new") edge layout so it works regardless of which is installed:
#   Scheduled task name: old=ObservoEdge   new=observo-edge
#   Binaries:            old=edge*.exe + otelcontrib*.exe
#                        new=edge.exe + edge-watcher.exe + edge-worker.exe
#   New-only dir:        $InstallDir\update
# All removals are best-effort: missing resources are logged and skipped
# (not fatal), since old- and new-layout artifacts rarely coexist.
#
# $InstallDir mirrors install.ps1's Get-EnvOrDefault(ROOT_DIR/INSTALL_DIR)
# resolution -- previously hardcoded here, which silently broke uninstall
# for any install done with a custom ROOT_DIR/INSTALL_DIR (OBE-12500).
function Get-EnvOrDefault {
    param([string]$Name, [string]$Default)
    $val = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($val)) { return $Default }
    return $val
}
$InstallDir  = Get-EnvOrDefault "ROOT_DIR" (Get-EnvOrDefault "INSTALL_DIR" "C:\Program Files\Observo")
$ConfigFile  = "$InstallDir\edge-config.json"
$HistoryDir  = "$InstallDir\history"
$LogDir      = "$InstallDir\logs"
$UpdateDir   = "$InstallDir\update"
$WrapperPath = "$InstallDir\run_observo.cmd"
$NssmPath    = "$InstallDir\nssm.exe"
# Both the current task name and the legacy one are cleaned up.
$ServiceNames  = @("observo-edge", "ObservoEdge")
# Process names covering old (otelcontribcol) and new (edge-watcher/worker) layouts.
$ProcessNames  = @("edge", "edge-watcher", "edge-worker", "otelcontribcol")
# Least-privilege local service account created by install.ps1 (OBE-12500 AC3).
$ServiceAccountName = Get-EnvOrDefault "SERVICE_ACCOUNT_NAME" "svc-observo-edge"

function Stop-ObservoTask {
    foreach ($name in $ServiceNames) {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($task) {
            Write-Host "Stopping scheduled task: $name..."
            Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Write-Host "Unregistering scheduled task: $name..."
            try {
                Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
            } catch {
                Write-Host "Warning: failed to unregister scheduled task '$name': $_" -ForegroundColor Yellow
            }
        }

        # Any registered Windows service of this name: the current
        # installer registers one via NSSM, and the old installer(s)
        # could also register one directly. `nssm remove` cleans up
        # NSSM's own registry keys more reliably than a raw
        # `sc.exe delete` against an NSSM-wrapped service, so prefer it
        # when nssm.exe is present.
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc) {
            Write-Host "Stopping and removing Windows service: $name..."
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            if (Test-Path -Path $NssmPath) {
                & $NssmPath remove $name confirm | Out-Null
            } else {
                sc.exe delete $name | Out-Null
            }
        }
    }
}

function Remove-ObservoServiceAccount {
    $account = Get-LocalUser -Name $ServiceAccountName -ErrorAction SilentlyContinue
    if (-not $account) {
        Write-Host "Service account $ServiceAccountName not found, skipping."
        return
    }
    Write-Host "Removing service account: $ServiceAccountName..."
    try {
        Remove-LocalUser -Name $ServiceAccountName -ErrorAction Stop
    } catch {
        Write-Host "Warning: failed to remove service account '$ServiceAccountName': $_" -ForegroundColor Yellow
    }
}

function Stop-ObservoProcesses {
    Write-Host "Checking for running Observo processes..."
    foreach ($name in $ProcessNames) {
        $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
        foreach ($proc in $procs) {
            Write-Host "Stopping process $name (PID $($proc.Id))..."
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            } catch {
                Write-Host "Warning: failed to stop process $name (PID $($proc.Id)): $_" -ForegroundColor Yellow
            }
        }
    }
    Start-Sleep -Seconds 1
}

function Remove-WrapperScript {
    if (-not (Test-Path -Path $WrapperPath)) {
        Write-Host "Wrapper script $WrapperPath not found, skipping."
        return
    }
    Write-Host "Removing wrapper script: $WrapperPath..."
    try {
        Remove-Item -Path $WrapperPath -Force -ErrorAction Stop
    } catch {
        Write-Host "Warning: failed to remove wrapper script: $_" -ForegroundColor Yellow
    }
}

function Remove-Binaries {
    if (-not (Test-Path -Path $InstallDir)) {
        Write-Host "Install directory $InstallDir not found, skipping binary removal."
        return
    }
    Write-Host "Removing binaries from $InstallDir..."

    # edge*.exe covers edge.exe, edge-watcher.exe, edge-worker.exe (new) and
    # any old edge*.exe; otelcontrib*.exe covers the legacy collector binary.
    $binaries  = @(Get-ChildItem -Path $InstallDir -Filter "edge*.exe"        -ErrorAction SilentlyContinue)
    $binaries += @(Get-ChildItem -Path $InstallDir -Filter "otelcontrib*.exe" -ErrorAction SilentlyContinue)

    if ($binaries.Count -eq 0) {
        Write-Host "No binaries found in $InstallDir, skipping."
        return
    }

    foreach ($bin in $binaries) {
        Write-Host "Removing $($bin.FullName)..."
        try {
            Remove-Item -Path $bin.FullName -Force -ErrorAction Stop
        } catch {
            Write-Host "Warning: failed to remove $($bin.FullName): $_" -ForegroundColor Yellow
        }
    }
}

function Remove-Config {
    if ($KeepConfig) {
        Write-Host "Keeping config file (-KeepConfig set): $ConfigFile"
    } elseif (-not (Test-Path -Path $ConfigFile)) {
        Write-Host "Config file $ConfigFile not found, skipping."
    } else {
        Write-Host "Removing config file: $ConfigFile..."
        try {
            Remove-Item -Path $ConfigFile -Force -ErrorAction Stop
        } catch {
            Write-Host "Warning: failed to remove config file: $_" -ForegroundColor Yellow
        }
    }

    # The history dir is not the config file, so it is always removed (even
    # with -KeepConfig, which keeps only edge-config.json).
    if (Test-Path -Path $HistoryDir) {
        Write-Host "Removing config history directory: $HistoryDir..."
        try {
            Remove-Item -Path $HistoryDir -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Host "Warning: failed to remove history directory: $_" -ForegroundColor Yellow
        }
    }
}

function Remove-LogDir {
    # Logs are never preserved; always removed.
    if (-not (Test-Path -Path $LogDir)) {
        Write-Host "Log directory $LogDir not found, skipping."
        return
    }
    Write-Host "Removing log directory: $LogDir..."
    try {
        Remove-Item -Path $LogDir -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Host "Warning: failed to remove log directory: $_" -ForegroundColor Yellow
    }
}

function Remove-UpdateDir {
    # The update staging dir holds transient in-flight update artifacts (new
    # layout only). Safe to remove even when config/logs are preserved.
    if (-not (Test-Path -Path $UpdateDir)) {
        return
    }
    Write-Host "Removing update staging directory: $UpdateDir..."
    try {
        Remove-Item -Path $UpdateDir -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Host "Warning: failed to remove update directory: $_" -ForegroundColor Yellow
    }
}

function Remove-InstallDir {
    # When -KeepConfig is set we preserve the directory because edge-config.json
    # lives inside it; every other entry (binaries, logs, update dir, history)
    # is removed by the other always-run steps, leaving only edge-config.json.
    if ($KeepConfig) {
        Write-Host "Preserving install directory (only $ConfigFile retained): $InstallDir"
        return
    }

    if (-not (Test-Path -Path $InstallDir)) {
        Write-Host "Install directory $InstallDir not found, skipping."
        return
    }
    Write-Host "Removing install directory: $InstallDir..."
    try {
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Host "Warning: failed to remove install directory: $_" -ForegroundColor Yellow
    }
}

Write-Host "Uninstalling Observo Edge..."

# Step 1: Stop and unregister scheduled task / service
Stop-ObservoTask

# Step 2: Kill any remaining processes
Stop-ObservoProcesses

# Step 2b: Remove the least-privilege service account (OBE-12500)
Remove-ObservoServiceAccount

# Step 3: Remove wrapper script
Remove-WrapperScript

# Step 4: Remove binaries
Remove-Binaries

# Step 5: Remove config
Remove-Config

# Step 6: Remove log directory
Remove-LogDir

# Step 7: Remove update staging directory (new layout only)
Remove-UpdateDir

# Step 8: Remove install directory
Remove-InstallDir

Write-Host "Observo Edge uninstalled successfully."
# Observo Edge Installation Script for Windows
# This script installs and configures the Observo Edge agent

# ASCII Art Banner
$ObservoHeading = @"
       #######    ######      #####     #######    ######     #     #    #######              #       ###
       #     #    #     #    #     #    #          #     #    #     #    #     #             # #       #
       #     #    #     #    #          #          #     #    #     #    #     #            #   #      #
       #     #    ######      #####     #####      ######     #     #    #     #           #     #     #
       #     #    #     #          #    #          #   #       #   #     #     #    ###    #######     #
       #     #    #     #    #     #    #          #    #       # #      #     #    ###    #     #     #
       #######    ######      #####     #######    #     #       #       #######    ###    #     #    ###




 ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### #####




 ####### ######   #####  #######    ### #     #  #####  #######    #    #       #          #    ####### ### ####### #     #
 #       #     # #     # #           #  ##    # #     #    #      # #   #       #         # #      #     #  #     # ##    #
 #       #     # #       #           #  # #   # #          #     #   #  #       #        #   #     #     #  #     # # #   #
 #####   #     # #  #### #####       #  #  #  #  #####     #    #     # #       #       #     #    #     #  #     # #  #  #
 #       #     # #     # #           #  #   # #       #    #    ####### #       #       #######    #     #  #     # #   # #
 #       #     # #     # #           #  #    ## #     #    #    #     # #       #       #     #    #     #  #     # #    ##
 ####### ######   #####  #######    ### #     #  #####     #    #     # ####### ####### #     #    #    ### ####### #     #

"@

# Configuration Variables
# Path resolution: env var > platform default. Every variable below is
# overridable via the matching Windows environment variable so operators
# can relocate binaries / config / logs without editing the script.
# LoadEdgeConfig on the edge binary reads these on first boot and persists
# them into edge-config.json (env > json > default, bidirectional sync).
function Get-EnvOrDefault {
    param([string]$Name, [string]$Default)
    $val = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($val)) { return $Default }
    return $val
}

# Single root directory for the whole edge install. All other paths
# are derived from this so an operator only overrides one variable to
# relocate the install. Mirrors internal/server/constant_windows.go (RootDir).
$RootDir    = Get-EnvOrDefault "ROOT_DIR" (Get-EnvOrDefault "INSTALL_DIR" "C:\Program Files\Observo")
$InstallDir = $RootDir
$ConfigDir  = $RootDir
$LogDir     = Get-EnvOrDefault "LOG_DIR"     "$RootDir\logs"
# UpdateDir is the on-disk staging area for in-flight updates. Must
# match server.DefaultUpdateStagingDir in
# internal/server/constant_windows.go ($RootDir\update).
$UpdateDir = Get-EnvOrDefault "UPDATE_DIR" "$RootDir\update"
# DataDir is the dataplane (Vector) worker's persistent state directory
# (disk buffers, source checkpoints, validate_tmp). Must match
# server.DefaultWorkerDataDir in internal/server/constant_windows.go
# ($RootDir\data). Not created lazily by the worker -- must exist before
# validate/start or the worker fails with "data_dir ... does not exist".
$DataDir = Get-EnvOrDefault "WORKER_DATA_DIR" "$RootDir\data"
$TmpDir     = Get-EnvOrDefault "TMP_DIR"     "$env:TEMP\observo"
$ZipFile    = "$TmpDir\edge.zip"
$ExtractDir = "$TmpDir\binaries_edge"

# Per-binary paths. Must match internal/server/constant_windows.go defaults:
# binaries + edge-config.json + effective.yaml live directly in $RootDir;
# logs go under $RootDir\logs; update staging under $RootDir\update.
$EdgeExecutable       = Get-EnvOrDefault "EDGE_EXECUTABLE"        "$RootDir\edge.exe"
$WatcherExecutable    = Get-EnvOrDefault "WATCHER_EXECUTABLE"     "$RootDir\edge-watcher.exe"
$WorkerExecutablePath = Get-EnvOrDefault "WORKER_EXECUTABLE_PATH" "$RootDir\edge-worker.exe"
$WorkerConfigPath     = Get-EnvOrDefault "WORKER_CONFIG_PATH"     "$RootDir\effective.yaml"
$WorkerLogFilePath    = Get-EnvOrDefault "WORKER_LOG_FILE_PATH"   "$LogDir\edge-worker.log"
$EdgeConfigPath       = Get-EnvOrDefault "EDGE_CONFIG_PATH"       "$RootDir\edge-config.json"

$ConfigFile   = $EdgeConfigPath
$ServiceName  = Get-EnvOrDefault "SERVICE_NAME" "observo-edge"
# Single combined log file, matching Linux (systemd unit writes
# StandardOutput/StandardError to $LOG_DIR/observo-edge.log) and macOS
# (launchd plist points both StdoutPath and StderrPath at the same
# $LOG_DIR/observo-edge.log). The cmd wrapper below redirects 2>&1 into
# $StdoutLogFile so a single file captures everything.
$StdoutLogFile = "$LogDir\observo-edge.log"
$StderrLogFile = "$LogDir\observo-edge.log"
$EdgeCollectorLogFile = $WorkerLogFilePath

$DefaultDownloadUrl = "https://example.com"

# Bundle binary names (authoritative; must match the Bundle*Binary
# constants in updatemanager/config.go). On Windows the release bundle is
# a .zip (produced by CI as edge-windows-<version>.zip); the update
# watcher auto-detects zip vs tar.gz from the archive's magic bytes and
# uses archive/zip on Windows. Inside the archive the files may or may
# not carry the .exe suffix — the watcher strips .exe before matching.
# The installer itself searches for basename match (Get-ChildItem -Filter
# "edge*.exe") and copies to the resolved *.exe destinations.
$EdgeBinaryName    = "edge.exe"
$WatcherBinaryName = "edge-watcher.exe"
$WorkerBinaryName  = "edge-worker.exe"
# Bundle file always has the same name on disk (the download URL may be
# a presigned S3 URL with a randomised query string; save name is local).
$ZipFile = "$TmpDir\edge.zip"
# Function to check for and install prerequisites
function Check-Prerequisites {
    Write-Host "Checking for required PowerShell modules..."

    # Only check for NuGet if PowerShell version is older than 5.1
    if ($PSVersionTable.PSVersion.Major -lt 5 -or ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
        # Check if the NuGet package provider is installed
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Write-Host "Installing NuGet package provider..."
            Install-PackageProvider -Name NuGet -Force -Scope CurrentUser
        }
    } else {
        Write-Host "PowerShell 5.1 or later detected, skipping NuGet package provider check."
    }

    # Check for required modules
    $requiredModules = @("Microsoft.PowerShell.Archive")
    foreach ($module in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-Host "Installing module: $module..."
            Install-Module -Name $module -Force -Scope CurrentUser
        } else {
            Write-Host "$module is already installed."
        }
    }
}

# Function to parse command line arguments
function Parse-EnvironmentVariable {
    param (
        [Parameter(Mandatory=$false)]
        [string]$EnvVar
    )

    if (-not $EnvVar) {
        Write-Host "Error: Missing -EnvVar argument"
        Write-Host "Usage: .\install-observo.ps1 -EnvVar 'install_id=<JWT Token> download_url=<Custom URL>'"
        return $false
    }

    Write-Host "Received environment variable: $EnvVar"

    # Parse install_id
    if ($EnvVar -match "install_id=([A-Za-z0-9+/=]+)") {
        $script:Token = $matches[1]
        Write-Host "Extracted install_id (base64): $Token"

        try {
            # Decode the base64 string
            $bytes = [Convert]::FromBase64String($Token)
            $script:Decoded = [System.Text.Encoding]::UTF8.GetString($bytes)
            Write-Host "Decoded install_id (JSON): $Decoded"
        } catch {
            Write-Host "Error decoding base64 string: $_"
            return $false
        }
    } else {
        Write-Host "Error: install_id not found in argument"
        return $false
    }

    # Parse download_url (optional) and update DefaultDownloadUrl directly
    if ($EnvVar -match "download_url=([^\s]+)") {
        $script:DefaultDownloadUrl = $matches[1]
        Write-Host "Updated DefaultDownloadUrl to: $DefaultDownloadUrl"
    } else {
        Write-Host "No DownloadUrl provided: $DefaultDownloadUrl"
        return $false
    }

    # Parse checksum=<base64-sha256> — see install.sh for full rationale.
    # S3 ChecksumSHA256 is base64-encoded; we verify the downloaded
    # bundle against it before extracting. Mandatory.
    if ($EnvVar -match "checksum=([A-Za-z0-9+/=]+)") {
        $script:ExpectedChecksum = $matches[1]
        Write-Host "Extracted checksum: $ExpectedChecksum"
    } else {
        Write-Host "Error: checksum not found in argument"
        return $false
    }

    return $true
}

function Detect-System {
    $OS = "windows"

    # Determine architecture
    if ([Environment]::Is64BitOperatingSystem) {
        $script:Arch = "amd64"
        Write-Host "Detected 64-bit Windows architecture (amd64)"
    } else {
        Write-Host "Error: Your system architecture is not supported. 64-bit Windows is required." -ForegroundColor Red
        exit 1
    }

    Write-Host "Detected OS: $OS"
    Write-Host "Detected Architecture: $Arch"

    $script:OS = $OS
}

# Function to decode and extract configuration
function Decode-AndExtractConfig {
    Write-Host "Processing token: $Token"

    # Create config directory if it doesn't exist
    if (-not (Test-Path -Path $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }

    # Create a history subdirectory for timestamped configs
    $HistoryDir = Join-Path -Path $ConfigDir -ChildPath "history"
    if (-not (Test-Path -Path $HistoryDir)) {
        New-Item -ItemType Directory -Path $HistoryDir -Force | Out-Null
    }

    # Create timestamp for historical file
    $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $HistoricalConfigFile = Join-Path -Path $HistoryDir -ChildPath "edge-config-$Timestamp.json"

    # Parse JSON configuration
    try {
        $config = $Decoded | ConvertFrom-Json

        $script:SiteId = $config.site_id
        $script:AuthToken = $config.auth_token
        $script:AgentVersion = $config.agent_version
        $script:ConfigVersionId = $config.config_version_id
        $script:FleetId = $config.fleet_id
        $script:Platform = $config.platform
        $script:EdgeManagerUrl = $config.edge_manager_url

        Write-Host "SITE_ID: $SiteId"
        Write-Host "AUTH_TOKEN: $AuthToken"
        Write-Host "AGENT_VERSION: $AgentVersion"
        Write-Host "CONFIG_VERSION_ID: $ConfigVersionId"
        Write-Host "FLEET_ID: $FleetId"
        Write-Host "PLATFORM: $Platform"
        Write-Host "EDGE_MANAGER_URL: $EdgeManagerUrl"
    } catch {
        Write-Host "Error parsing JSON configuration: $_" -ForegroundColor Red
        exit 1
    }

    # edge_manager_tls_enabled is derived from the URL scheme rather than
    # trusted from the payload: the enrollment HTTP client (EnsureEnrolled ->
    # enrollEndpoint) reads this flag to decide http:// vs https://, with no
    # fallback/retry if it guesses wrong (unlike the OpAMP client's
    # schemeFlip). A wss:// (or https://) edge_manager_url with this flag
    # left false/unset makes enrollment fail permanently against a TLS-only
    # ingress -- fatal after 10 attempts, then crash-loop under the service
    # manager.
    $edgeManagerTlsEnabled = $EdgeManagerUrl -match '^(wss|https)://'
    $config | Add-Member -NotePropertyName "edge_manager_tls_enabled" -NotePropertyValue $edgeManagerTlsEnabled -Force
    $DecodedWithTls = $config | ConvertTo-Json -Depth 10

    # Write JSON (now carrying edge_manager_tls_enabled) to both current and
    # historical config files.
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($ConfigFile, $DecodedWithTls, $utf8NoBom)
    [System.IO.File]::WriteAllText($HistoricalConfigFile, $DecodedWithTls, $utf8NoBom)

    Write-Host "Configuration saved to $ConfigFile"
    Write-Host "Historical copy saved to $HistoricalConfigFile"
}

# Download the release bundle and extract it.
#
# On Windows the release bundle is a .zip (same format CI has always shipped
# for this platform). The update watcher auto-detects zip vs tar.gz from
# magic bytes, so in-place updates re-extract with the same format.
# Expand-Archive is the native PowerShell cmdlet and avoids a tar dependency.
function Download-AndExtractAgent {
    param (
        [string]$DownloadUrl = $DefaultDownloadUrl
    )

    if (-not (Test-Path -Path $TmpDir)) {
        New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null
    }

    Write-Host "Downloading from $DownloadUrl"
    try {
        # WebClient handles S3 presigned URLs fine; -UseBasicParsing flag of
        # Invoke-WebRequest is PS-version-sensitive, so stick with WebClient.
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($DownloadUrl, $ZipFile)
    } catch {
        Write-Host "Error downloading bundle: $_" -ForegroundColor Red
        exit 1
    }

    # Sanity-check: presigned URL expiry errors come back as small XML docs.
    $size = (Get-Item $ZipFile).Length
    if ($size -lt 10240) {
        Write-Host "Error: bundle is suspiciously small ($size bytes); presigned URL may be expired." -ForegroundColor Red
        Get-Content $ZipFile -Raw | Select-Object -First 400 | Write-Host
        exit 1
    }
    Write-Host "Download saved to $ZipFile ($size bytes)"

    # Verify SHA256 against the value fleet-manager read from S3's
    # ChecksumSHA256 attribute (base64-encoded). Get-FileHash returns
    # hex; convert to base64 so we compare in the same form S3 emits.
    # Fail closed on mismatch — do NOT extract an unverified binary.
    $hexHash = (Get-FileHash -Path $ZipFile -Algorithm SHA256).Hash
    $hashBytes = New-Object byte[] ($hexHash.Length / 2)
    for ($i = 0; $i -lt $hashBytes.Length; $i++) {
        $hashBytes[$i] = [Convert]::ToByte($hexHash.Substring($i * 2, 2), 16)
    }
    $ActualChecksum = [Convert]::ToBase64String($hashBytes)
    if ($ActualChecksum -ne $ExpectedChecksum) {
        Write-Host "Error: checksum mismatch for $ZipFile" -ForegroundColor Red
        Write-Host "  expected (from S3): $ExpectedChecksum" -ForegroundColor Red
        Write-Host "  actual (computed):  $ActualChecksum"   -ForegroundColor Red
        Write-Host "Refusing to install a tampered or corrupted binary." -ForegroundColor Red
        exit 1
    }
    Write-Host "Checksum verified: $ActualChecksum"

    if (-not (Test-Path -Path $ExtractDir)) {
        New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null
    }

    Write-Host "Extracting $ZipFile to $ExtractDir"
    try {
        Expand-Archive -Path $ZipFile -DestinationPath $ExtractDir -Force
    } catch {
        Write-Host "Error during zip extraction: $_" -ForegroundColor Red
        exit 1
    }
    Write-Host "Extraction complete. Files are in $ExtractDir"
}

function Move-BinariesToInstallDir {
    # The release .zip contains three Windows binaries:
    # edge.exe, edge-watcher.exe, edge-worker.exe. They get copied to the
    # destinations resolved earlier from env vars (or defaults). Subsequent
    # edge boots read these env vars via LoadEdgeConfig and persist them
    # into edge-config.json.
    # Lay down the canonical directory tree:
    #   $RootDir\           binaries + edge-config.json + effective.yaml
    #   $RootDir\logs\      supervisor + worker + update-watcher logs
    #   $RootDir\update\    staging dir + heartbeat (if used) + flag file
    #   $RootDir\data\      dataplane (Vector) worker persistent state
    foreach ($d in @($RootDir, $LogDir, $UpdateDir, $DataDir)) {
        if (-not (Test-Path -Path $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Write-Host "Created directory: $d"
        }
    }

    function Install-Binary {
        param([string]$SourceName, [string]$DestPath)

        $src = Get-ChildItem -Path $ExtractDir -Recurse -Filter $SourceName |
            Select-Object -First 1 -ExpandProperty FullName
        if (-not $src) {
            Write-Host "Error: $SourceName not found in bundle at $ExtractDir" -ForegroundColor Red
            exit 1
        }

        # If the destination exists and is locked by a running process, stop it.
        if (Test-Path -Path $DestPath) {
            try {
                $processes = Get-Process | Where-Object { $_.Modules.FileName -eq $DestPath }
                foreach ($p in $processes) {
                    Write-Host "Stopping process $($p.Id) holding $DestPath"
                    Stop-Process -Id $p.Id -Force
                    Start-Sleep -Seconds 1
                }
            } catch {
                Write-Host "Warning: could not check locks on ${DestPath}: $_"
            }
        }

        $destDir = Split-Path $DestPath -Parent
        if (-not (Test-Path -Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        Write-Host "Installing $src -> $DestPath"
        Copy-Item -Path $src -Destination $DestPath -Force
    }

    Install-Binary -SourceName $EdgeBinaryName    -DestPath $EdgeExecutable
    Install-Binary -SourceName $WatcherBinaryName -DestPath $WatcherExecutable
    Install-Binary -SourceName $WorkerBinaryName  -DestPath $WorkerExecutablePath

    # All three binaries must have IDENTICAL ACLs / ownership.
    # The supervisor fork-execs edge-watcher.exe at update time under
    # the SYSTEM account (or whichever Identity the scheduled task is
    # bound to); a mismatch surfaces as "Access is denied" mid-update.
    # We canonicalise by copying the edge.exe ACL onto its siblings so
    # whatever group/owner edge.exe ended up with, the watcher and
    # worker match it bit-for-bit.
    try {
        $edgeAcl = Get-Acl -Path $EdgeExecutable
        Set-Acl -Path $WatcherExecutable    -AclObject $edgeAcl
        Set-Acl -Path $WorkerExecutablePath -AclObject $edgeAcl
        Write-Host "Aligned ACLs of $WatcherExecutable and $WorkerExecutablePath with $EdgeExecutable"
    } catch {
        Write-Host "Warning: failed to align ACLs across edge binaries: $_" -ForegroundColor Yellow
    }

    # Sanity check: confirm we can actually execute each binary. If
    # this fails the supervisor will fail the same way at update
    # time, so it's much better to surface it during install.
    foreach ($bin in @($EdgeExecutable, $WatcherExecutable, $WorkerExecutablePath)) {
        if (-not (Test-Path -Path $bin -PathType Leaf)) {
            Write-Host "Error: $bin is missing after install" -ForegroundColor Red
            exit 1
        }
    }

    # Clean up temp extract dir
    Write-Host "Cleaning up temporary files..."
    Remove-Item -Path $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $TmpDir -Recurse -Force -ErrorAction SilentlyContinue

    # The scheduled-task wrapper below uses $EdgeExe.
    $script:EdgeExe = $EdgeExecutable
    $script:OtelExecutablePath = $WorkerExecutablePath
}


function Install-AsScheduledTask {
    Write-Host "Installing Observo Edge as a scheduled task..."

    # Check if service already exists and remove it
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Write-Host "Service exists. Stopping and removing..."
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        sc.exe delete $ServiceName
        Start-Sleep -Seconds 2
    }

    # Check if task already exists and remove it
    $taskExists = Get-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue
    if ($taskExists) {
        Write-Host "Scheduled task exists. Removing..."
        Unregister-ScheduledTask -TaskName $ServiceName -Confirm:$false
    }

    # Verify the binary and config file exist
    Write-Host "Verifying binary and config file exist:"
    $binaryExists = Test-Path -Path $EdgeExe
    $configExists = Test-Path -Path $ConfigFile
    Write-Host "Binary: $binaryExists"
    Write-Host "Config: $configExists"

    if (-not $binaryExists -or -not $configExists) {
        Write-Host "Error: Binary or config file missing!" -ForegroundColor Red
        exit 1
    }

    # Create log directory if it doesn't exist
    if (-not (Test-Path -Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        Write-Host "Created log directory: $LogDir"
    }
    # SECURITY: AGENT_ID is no longer derived on the client (previously the
    # registry MachineGuid). A client-chosen UID is self-asserted identity.
    # Identity is now server-assigned: the edge performs an enrollment exchange
    # (/enroll) on first boot and persists the server-assigned instance_uid +
    # per-agent token to edge-config.json.

    # Wrapper script that exports every env var the edge expects on boot
    # (LoadEdgeConfig will read these and persist to edge-config.json).
    # The list MUST stay in sync with the systemd unit in install.sh and
    # the launchd plist in install_darwin.sh — those three define the
    # cross-platform contract for what the edge service sees at boot.
    # Keep aligned with internal/server/constant.go.
    $WrapperScript = @"
@echo off
REM AGENT_ID intentionally not set: identity is server-assigned via enrollment
REM and persisted to edge-config.json on first boot.
set SITE_ID=$SiteId
set AUTH_TOKEN=$AuthToken
set AGENT_VERSION=$AgentVersion
set CONFIG_VERSION_ID=$ConfigVersionId
set FLEET_ID=$FleetId
set PLATFORM=$Platform
set EDGE_MANAGER_URL=$EdgeManagerUrl
set EDGE_CONFIG_PATH=$EdgeConfigPath
set EDGE_EXECUTABLE=$EdgeExecutable
set WATCHER_EXECUTABLE=$WatcherExecutable
set WORKER_EXECUTABLE_PATH=$WorkerExecutablePath
set WORKER_CONFIG_PATH=$WorkerConfigPath
set WORKER_LOG_FILE_PATH=$WorkerLogFilePath
set WORKER_DATA_DIR=$DataDir
echo Starting Observo Edge Agent at %DATE% %TIME% > "$StdoutLogFile"
    "$EdgeExe" -config "$ConfigFile" >> "$StdoutLogFile" 2>&1
"@

    $WrapperPath = "$InstallDir\run_observo.cmd"
    Set-Content -Path $WrapperPath -Value $WrapperScript
    Write-Host "Created wrapper script: $WrapperPath"

    # Create the action to run the wrapper script
    $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$WrapperPath`""

    # Create the trigger (at system startup)
    $trigger = New-ScheduledTaskTrigger -AtStartup

    # Configure the settings
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 0) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

    # Create the principal (run as SYSTEM with highest privileges)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    # Register the task
    Register-ScheduledTask -TaskName $ServiceName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Observo Edge telemetry collection agent"

    # Start the task immediately
    Write-Host "Starting scheduled task: $ServiceName"
    Start-ScheduledTask -TaskName $ServiceName

    # Check if the task started and the process is running
    Start-Sleep -Seconds 5
    $processes = Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($EdgeExe)) -ErrorAction SilentlyContinue

    if ($processes.Count -gt 0) {
        Write-Host "Observo Edge started successfully as a scheduled task." -ForegroundColor Green
        Write-Host "Process ID(s): $($processes.Id -join ', ')"
    } else {
        Write-Host "Warning: The scheduled task was created but the process may not have started." -ForegroundColor Yellow
    }

    # Show the scheduled task status
    Get-ScheduledTask -TaskName $ServiceName | Format-List State, LastRunTime, LastTaskResult
}

# Main execution flow
Write-Host $ObservoHeading

# Parse command line arguments
$installId = $args[1]
if (-not (Parse-EnvironmentVariable -EnvVar $installId)) {
    Write-Host "Usage: .\install-observo.ps1 -EnvVar 'install_id=<JWT Token> download_url=<Custom URL>'"
    Write-Host "Note: download_url is optional. If not provided, the default URL will be used."
    exit 1
}

# Add a function to view the logs
function View-ObservoLogs {
    param (
        [Parameter(Mandatory=$false)]
        [int]$Lines = 50,

        [Parameter(Mandatory=$false)]
        [switch]$Errors,

        [Parameter(Mandatory=$false)]
        [switch]$Follow
    )

    $LogFile = if ($Errors) { $StderrLogFile } else { $StdoutLogFile }

    if (-not (Test-Path -Path $LogFile)) {
        Write-Host "Log file not found: $LogFile" -ForegroundColor Yellow
        return
    }

    if ($Follow) {
        Write-Host "Showing logs from $LogFile (Press Ctrl+C to exit)" -ForegroundColor Cyan
        Get-Content -Path $LogFile -Tail $Lines -Wait
    } else {
        Write-Host "Last $Lines lines from ${LogFile}:" -ForegroundColor Cyan
        Get-Content -Path $LogFile -Tail $Lines
    }
}

function Show-InstallationCompleteMessage {
    Write-Host "Installation completed!"
    Write-Host ""
    Write-Host "Log file is stored at: $StdoutLogFile"
}

# Check prerequisites
Check-Prerequisites

# Detect system architecture
Detect-System

# Decode and extract configuration
Decode-AndExtractConfig

# Download and extract the agent
Download-AndExtractAgent

# Move binaries to installation directory
Move-BinariesToInstallDir

# Install and start service
Install-AsScheduledTask

Show-InstallationCompleteMessage
# Observo Edge Installation in Windows System

## Overview

This PowerShell script automates the installation and configuration of the Observo Edge agent on Windows systems. It registers the agent as a Windows Service (via a bundled [NSSM](http://nssm.cc) wrapper), running under a dedicated least-privilege local account by default, and provides comprehensive logging capabilities.

## System Requirements

- **Operating System**: Windows (64-bit only)
- **Architecture**: AMD64/x86_64 architecture
- **PowerShell**: Version 5.1 or higher recommended
- **Permissions**: Administrative privileges required for installation
## Dependencies & Tools

- **PowerShell Modules**:
    - Microsoft.PowerShell.Archive (for extracting the agent binaries)
    - NuGet package provider (Automatically installed if Powershell version less than 5.1)

## Installation Process

1. Validates prerequisites and PowerShell modules
2. Detects system architecture to confirm compatibility
3. Decodes the provided token to extract agent configuration
4. Downloads and extracts the agent binaries from a secure URL
5. Moves binaries to the installation directory (`C:\Program Files\Observo`)
6. Creates a dedicated least-privilege local service account (or reuses `LocalSystem` if
   `USE_SYSTEM_ACCOUNT=true` is set) and registers the agent as a Windows Service via NSSM, running
   under that account
7. Hardens ACLs on the installation directory and every file that carries the auth token
8. Configures log redirection to capture all agent output

## Installation Command

Run the script with the installation token:
```powershell
.\install-observo.ps1 -e 'install_id=<Token>'
```

## Monitoring & Management

### Log Location
All agent output is consolidated in a single log file:
```
C:\Program Files\Observo\logs\observoedge_stdout.log
```

### Checking Process Status
To verify the agent is running:
```powershell
Get-Process -Name "edge" -ErrorAction SilentlyContinue
```

### Managing the Windows Service
```powershell
# View service status
Get-Service -Name "observo-edge"

# Stop the agent
Stop-Service -Name "observo-edge"

# Start the agent
Start-Service -Name "observo-edge"
```

### Process Management
```powershell
# Stop the agent process
Stop-Process -Name "edge" -Force

# Find process ID
Get-Process -Name "edge" | Select-Object Id
```

## Installation Artifacts

- **Installation Directory**: `C:\Program Files\Observo`
- **Configuration File**: `C:\Program Files\Observo\edge-config.json`
- **Historical Configs**: `C:\Program Files\Observo\history\` (retained: last 10 by default)
- **Service Wrapper**: `C:\Program Files\Observo\nssm.exe` (bundled, public domain)
- **Windows Service**: `observo-edge` (visible via `Get-Service`)
- **Service Account**: `svc-observo-edge` (local, least-privilege, non-interactive)

## Troubleshooting

- Check the log file for detailed error messages
- Verify the service is running: `Get-Service -Name "observo-edge"` should show `Running`
- Confirm the system has network connectivity to the Observo backend
- Verify the agent has appropriate permissions to access required resources

## Security Considerations

- The agent runs under a dedicated local service account (`svc-observo-edge`) with no interactive
  logon rights, scoped to Event Log Readers membership, instead of `NT AUTHORITY\SYSTEM`. Set
  `USE_SYSTEM_ACCOUNT=true` at install time to opt back into running as `LocalSystem` if required.
- The installation directory and every file that carries the auth token (`edge-config.json`, its
  historical copies, and `run_observo.cmd`) have explicit, non-inherited ACLs limiting access to
  `SYSTEM`, `Administrators`, and the service account.
- The auth token is never written to console/transcript output during install.
- The `history\` directory is pruned to the 10 most recent configs on every install/reinstall.
- All configuration data is stored securely in the Program Files directory.
- The agent communicates with the Observo backend using secure authentication tokens.
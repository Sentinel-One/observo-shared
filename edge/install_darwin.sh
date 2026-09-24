#!/bin/bash
# Observo Edge installer for macOS (launchd).
#
# Usage:
#   sudo ./install-darwin.sh -e "install_id=<base64> download_url=<presigned-url>"
#
# The installer drops three binaries (edge, edge-watcher, edge-worker) at
# paths resolved from env vars (or sane defaults), writes the decoded
# edge-config.json, and registers a /Library/LaunchDaemons/<ServiceName>.plist
# that the launchdManager in internal/updatemanager/servicemanager.go knows
# how to restart during updates (`launchctl kickstart -k system/<name>`).
#
# Every path is overridable via environment variable so packagers can
# relocate things without editing the script. The edge binary's
# LoadEdgeConfig reads these env vars on first boot and persists them
# into edge-config.json (env > json > default, bidirectional).

set -euo pipefail

PREREQS="curl jq shasum"

# -----------------------------------------------------------------------------
# Path resolution: env var > platform default. Must mirror
# internal/server/constant_darwin.go.
# -----------------------------------------------------------------------------
# Single root directory for the whole edge install. Mirrors
# internal/server/constant_darwin.go (RootDir).
ROOT_DIR="${ROOT_DIR:-${INSTALL_DIR:-/opt/observo}}"
INSTALL_DIR="$ROOT_DIR"
CONFIG_DIR="$ROOT_DIR"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/logs}"
# UPDATE_DIR is the on-disk staging area for in-flight updates and the
# heartbeat socket the watcher uses to coordinate with the supervisor.
# Must match server.DefaultUpdateStagingDir in
# internal/server/constant_darwin.go ($ROOT_DIR/update).
UPDATE_DIR="${UPDATE_DIR:-$ROOT_DIR/update}"
# DATA_DIR is the dataplane (Vector) worker's persistent state directory
# (disk buffers, source checkpoints, validate_tmp). Must match
# server.DefaultWorkerDataDir in internal/server/constant_darwin.go
# ($ROOT_DIR/data). Not created lazily by the worker -- must exist before
# validate/start or the worker fails with "data_dir ... does not exist".
DATA_DIR="${WORKER_DATA_DIR:-$ROOT_DIR/data}"
TMP_DIR="${TMP_DIR:-/tmp/observo}"
TAR_FILE="$TMP_DIR/edge.tar.gz"
EXTRACT_DIR="$TMP_DIR/binaries_edge"

# Binaries sit directly in ROOT_DIR; logs go under logs/.
EDGE_EXECUTABLE="${EDGE_EXECUTABLE:-$ROOT_DIR/edge}"
WATCHER_EXECUTABLE="${WATCHER_EXECUTABLE:-$ROOT_DIR/edge-watcher}"
WORKER_EXECUTABLE_PATH="${WORKER_EXECUTABLE_PATH:-$ROOT_DIR/edge-worker}"
WORKER_CONFIG_PATH="${WORKER_CONFIG_PATH:-$ROOT_DIR/effective.yaml}"
WORKER_LOG_FILE_PATH="${WORKER_LOG_FILE_PATH:-$LOG_DIR/edge-worker.log}"
EDGE_CONFIG_PATH="${EDGE_CONFIG_PATH:-$ROOT_DIR/edge-config.json}"

CONFIG_FILE="$EDGE_CONFIG_PATH"

# Service name must match updatemanager.ServiceName AND the basename of the
# launchd plist (launchctl resolves services by plist basename in
# system/<name> form). `observo-edge` matches the Linux/Windows installers.
SERVICE_NAME="${SERVICE_NAME:-observo-edge}"
PLIST_PATH="/Library/LaunchDaemons/${SERVICE_NAME}.plist"

STDOUT_LOG="$LOG_DIR/observo-edge.log"
STDERR_LOG="$LOG_DIR/observo-edge.log"

# Bundle binary names.
EDGE_BINARY_NAME="edge"
WATCHER_BINARY_NAME="edge-watcher"
WORKER_BINARY_NAME="edge-worker"

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "This installer must run as root (try: sudo $0 ...)" >&2
        exit 1
    fi
}

dependencies_check() {
    for cmd in $PREREQS; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: required command '$cmd' is missing. Install it via brew or your package manager." >&2
            exit 1
        fi
    done
}

# -----------------------------------------------------------------------------
# Arg parsing (same contract as install.sh)
# -----------------------------------------------------------------------------

parse_environment_variable() {
    local env_var=""
    while getopts "e:" opt; do
        case "$opt" in
            e) env_var="$OPTARG";;
            *) echo "Usage: $0 -e 'install_id=<base64> download_url=<URL>'" >&2; return 1;;
        esac
    done
    OPTIND=1

    if [[ -z "$env_var" ]]; then
        echo "Error: missing -e argument" >&2
        return 1
    fi

    if [[ "$env_var" =~ install_id=([A-Za-z0-9+/=]+) ]]; then
        TOKEN="${BASH_REMATCH[1]}"
        export TOKEN
    else
        echo "Error: install_id not found" >&2
        return 1
    fi

    if [[ "$env_var" =~ download_url=([^\ ]+) ]]; then
        DOWNLOAD_URL="${BASH_REMATCH[1]}"
        export DOWNLOAD_URL
    else
        echo "Error: download_url not found" >&2
        return 1
    fi

    # checksum=<base64-sha256> — see install.sh for full rationale.
    # S3 ChecksumSHA256 is base64-encoded; we keep it in that form and
    # verify the downloaded tarball before extracting. Mandatory.
    if [[ "$env_var" =~ checksum=([A-Za-z0-9+/=]+) ]]; then
        EXPECTED_CHECKSUM="${BASH_REMATCH[1]}"
        export EXPECTED_CHECKSUM
    else
        echo "Error: checksum not found" >&2
        return 1
    fi
}

detect_system() {
    ARCH="$(uname -m)"
    case "$ARCH" in
        arm64|aarch64) ARCH=arm64 ;;
        x86_64)        ARCH=amd64 ;;
        *) echo "Unsupported macOS architecture: $ARCH" >&2; exit 1 ;;
    esac
    echo "Detected macOS / $ARCH"
}

# -----------------------------------------------------------------------------
# Config decode + binary install
# -----------------------------------------------------------------------------

decode_and_extract_config() {
    mkdir -p "$CONFIG_DIR"
    local padding=$(( 4 - ${#TOKEN} % 4 ))
    if [[ $padding -gt 0 && $padding -lt 4 ]]; then
        TOKEN+=$(printf '=%.0s' $(seq 1 $padding))
    fi

    local payload
    payload=$(printf '%s' "$TOKEN" | base64 -D 2>/dev/null || printf '%s' "$TOKEN" | base64 --decode)

    SITE_ID=$(echo "$payload" | jq -r '.site_id // empty')
    AUTH_TOKEN=$(echo "$payload" | jq -r '.auth_token // empty')
    AGENT_VERSION=$(echo "$payload" | jq -r '.agent_version // empty')
    CONFIG_VERSION_ID=$(echo "$payload" | jq -r '.config_version_id // empty')
    FLEET_ID=$(echo "$payload" | jq -r '.fleet_id // empty')
    PLATFORM=$(echo "$payload" | jq -r '.platform // empty')
    EDGE_MANAGER_URL=$(echo "$payload" | jq -r '.edge_manager_url // empty')

    # edge_manager_tls_enabled is derived from the URL scheme rather than
    # trusted from the payload: the enrollment HTTP client (EnsureEnrolled ->
    # enrollEndpoint) reads this flag to decide http:// vs https://, with no
    # fallback/retry if it guesses wrong (unlike the OpAMP client's
    # schemeFlip). A wss:// (or https://) edge_manager_url with this flag
    # left false/unset makes enrollment fail permanently against a TLS-only
    # ingress -- fatal after 10 attempts, then crash-loop under the service
    # manager.
    local edge_manager_tls_enabled
    case "$EDGE_MANAGER_URL" in
        wss://*|https://*) edge_manager_tls_enabled=true ;;
        *)                 edge_manager_tls_enabled=false ;;
    esac
    payload=$(echo "$payload" | jq --argjson tls "$edge_manager_tls_enabled" '. + {edge_manager_tls_enabled: $tls}')

    echo "$payload" > "$CONFIG_FILE"
    chmod 644 "$CONFIG_FILE"

    # SECURITY: AGENT_ID is no longer derived on the client (hardware UUID /
    # hostname). A client-chosen UID is self-asserted identity. Identity is now
    # server-assigned: the edge performs an enrollment exchange (/enroll) on
    # first boot and persists the server-assigned instance_uid + per-agent token
    # to edge-config.json. Do NOT reintroduce AGENT_ID derivation here.
    export SITE_ID AUTH_TOKEN AGENT_VERSION CONFIG_VERSION_ID FLEET_ID PLATFORM EDGE_MANAGER_URL
}

download_and_extract_agent() {
    mkdir -p "$TMP_DIR"
    echo "Downloading bundle from $DOWNLOAD_URL"
    curl -fL# "$DOWNLOAD_URL" -o "$TAR_FILE"

    local size
    size=$(stat -f%z "$TAR_FILE")
    if [[ $size -lt 10240 ]]; then
        echo "Error: bundle is suspiciously small ($size bytes); presigned URL may be expired." >&2
        exit 1
    fi

    # Verify SHA256 against the value fleet-manager read from S3's
    # ChecksumSHA256 attribute (base64-encoded). Computed the same way
    # the update watcher does: raw SHA256 → base64. Fail closed.
    local actual
    actual=$(shasum -a 256 -b "$TAR_FILE" | awk '{print $1}' | xxd -r -p | base64)
    if [[ "$actual" != "$EXPECTED_CHECKSUM" ]]; then
        echo "Error: checksum mismatch for $TAR_FILE" >&2
        echo "  expected (from S3): $EXPECTED_CHECKSUM" >&2
        echo "  actual (computed):  $actual" >&2
        echo "Refusing to install a tampered or corrupted binary." >&2
        exit 1
    fi
    echo "Checksum verified: $actual"

    mkdir -p "$EXTRACT_DIR"
    tar -xzf "$TAR_FILE" -C "$EXTRACT_DIR"
}

install_binary() {
    local src_name="$1"
    local dest_path="$2"

    local src
    src=$(find "$EXTRACT_DIR" -type f -name "$src_name" | head -n 1)
    if [[ -z "$src" ]]; then
        echo "Error: $src_name not found in bundle at $EXTRACT_DIR" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$dest_path")"
    echo "Installing $src -> $dest_path"
    mv "$src" "$dest_path"
    # Three things must be identical across edge / edge-watcher /
    # edge-worker, otherwise the supervisor's fork/exec of a sibling
    # binary fails with EPERM ("operation not permitted") even when the
    # binary itself is on disk:
    #   1. Ownership (root:wheel — matches launchd's parent process).
    #   2. Mode 0755 (executable bit on owner/group/other).
    #   3. NO quarantine / provenance xattrs. macOS attaches
    #      com.apple.quarantine to every file written by curl, Safari,
    #      AirDrop, etc.; an exec of a quarantined binary returns EPERM
    #      until the user clicks through Gatekeeper. We strip ALL
    #      xattrs (xattr -c) rather than only the named one so any
    #      provenance metadata that might block exec is cleared.
    chown root:wheel "$dest_path"
    chmod 0755 "$dest_path"
    xattr -c "$dest_path" 2>/dev/null || true
}

install_binaries() {
    # Lay down the canonical directory tree:
    #   $ROOT_DIR/        binaries + edge-config.json + effective.yaml
    #   $ROOT_DIR/logs/   supervisor + worker + update-watcher logs
    #   $ROOT_DIR/update/ staging dir + heartbeat socket + flag file
    #   $ROOT_DIR/data/   dataplane (Vector) worker persistent state
    mkdir -p "$ROOT_DIR" "$LOG_DIR" "$UPDATE_DIR" "$DATA_DIR"
    chown root:wheel "$ROOT_DIR" "$LOG_DIR" "$UPDATE_DIR" "$DATA_DIR"
    chmod 0755 "$ROOT_DIR" "$LOG_DIR" "$UPDATE_DIR" "$DATA_DIR"
    install_binary "$EDGE_BINARY_NAME"    "$EDGE_EXECUTABLE"
    install_binary "$WATCHER_BINARY_NAME" "$WATCHER_EXECUTABLE"
    install_binary "$WORKER_BINARY_NAME"  "$WORKER_EXECUTABLE_PATH"
    rm -rf "$EXTRACT_DIR" "$TAR_FILE"

    # Post-install sanity check. If we can't actually exec the watcher
    # right now, neither will the edge supervisor at update time and
    # we want that to fail loudly here rather than silently inside the
    # rollout. `--help`/`--version` would be ideal but the watcher has
    # no such flag; checking the kernel-loadable bit + xattr presence
    # is the next best signal.
    for bin in "$EDGE_EXECUTABLE" "$WATCHER_EXECUTABLE" "$WORKER_EXECUTABLE_PATH"; do
        if [[ ! -x "$bin" ]]; then
            echo "Error: $bin is not executable after install" >&2
            exit 1
        fi
        if xattr "$bin" 2>/dev/null | grep -q '^com\.apple\.quarantine'; then
            echo "Error: $bin still has com.apple.quarantine xattr after install" >&2
            exit 1
        fi
    done
}

# -----------------------------------------------------------------------------
# launchd registration
# -----------------------------------------------------------------------------
#
# The plist sets every path env var the edge binary expects on boot
# (same contract as install.sh's systemd unit). The launchdManager
# restarts this service via:
#   launchctl kickstart -k system/${SERVICE_NAME}
# so the plist's Label MUST equal ${SERVICE_NAME}.

create_launchd_plist() {
    echo "Writing launchd plist to $PLIST_PATH"
    mkdir -p "$LOG_DIR"
    cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${SERVICE_NAME}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${EDGE_EXECUTABLE}</string>
    <string>-config</string>
    <string>${CONFIG_FILE}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>WorkingDirectory</key>
  <string>${INSTALL_DIR}</string>
  <key>StandardOutPath</key>
  <string>${STDOUT_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${STDERR_LOG}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <!-- AGENT_ID intentionally omitted: identity is server-assigned via
         enrollment and persisted to edge-config.json on first boot. -->
    <key>SITE_ID</key><string>${SITE_ID}</string>
    <key>AUTH_TOKEN</key><string>${AUTH_TOKEN}</string>
    <key>AGENT_VERSION</key><string>${AGENT_VERSION}</string>
    <key>CONFIG_VERSION_ID</key><string>${CONFIG_VERSION_ID}</string>
    <key>FLEET_ID</key><string>${FLEET_ID}</string>
    <key>PLATFORM</key><string>${PLATFORM}</string>
    <key>EDGE_MANAGER_URL</key><string>${EDGE_MANAGER_URL}</string>
    <key>EDGE_CONFIG_PATH</key><string>${EDGE_CONFIG_PATH}</string>
    <key>EDGE_EXECUTABLE</key><string>${EDGE_EXECUTABLE}</string>
    <key>WATCHER_EXECUTABLE</key><string>${WATCHER_EXECUTABLE}</string>
    <key>WORKER_EXECUTABLE_PATH</key><string>${WORKER_EXECUTABLE_PATH}</string>
    <key>WORKER_CONFIG_PATH</key><string>${WORKER_CONFIG_PATH}</string>
    <key>WORKER_LOG_FILE_PATH</key><string>${WORKER_LOG_FILE_PATH}</string>
    <key>WORKER_DATA_DIR</key><string>${DATA_DIR}</string>
  </dict>
</dict>
</plist>
PLIST
    chown root:wheel "$PLIST_PATH"
    chmod 644 "$PLIST_PATH"
}

register_service() {
    # bootout is best-effort in case the service was never loaded before.
    launchctl bootout "system/${SERVICE_NAME}" 2>/dev/null || true
    launchctl bootstrap system "$PLIST_PATH"
    launchctl enable "system/${SERVICE_NAME}"
    launchctl kickstart -k "system/${SERVICE_NAME}"
    echo "Service ${SERVICE_NAME} started. Logs: $STDOUT_LOG"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

require_root
parse_environment_variable "$@"
dependencies_check
detect_system
decode_and_extract_config
download_and_extract_agent
install_binaries
create_launchd_plist
register_service

echo "Observo Edge installation complete."

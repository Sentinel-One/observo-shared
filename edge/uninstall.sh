#!/bin/bash

INSTALL_DIR="/opt/observo"
CONFIG_FILE="$INSTALL_DIR/edge-config.json"
OBSERVO_USER="observo"

# This uninstaller cleans up BOTH the legacy ("old") agent layout and the
# current ("new") edge layout so it works no matter which one is installed:
#
#   Linux systemd service:  old=observo-agent   new=observo-edge
#   macOS:                  old=raw "edge" nohup process
#                           new=launchd daemon observo-edge (plist below)
#   Binaries:               old=edge + otelcontrib*
#                           new=edge + edge-watcher + edge-worker
#   Logs:                   old=/var/log/observo
#                           new=$INSTALL_DIR/logs
#   New-only staging dir:   $INSTALL_DIR/update
#
# All removals are best-effort: a missing resource is logged and skipped
# (not fatal), since old- and new-layout artifacts rarely coexist.
SERVICE_NAMES=("observo-edge" "observo-agent")
LAUNCHD_LABELS=("observo-edge")
# Process names to kill (covers old + new across macOS/Linux).
PROCESS_NAMES=("edge" "edge-watcher" "edge-worker" "otelcontribcol" "otelcontrib")
# Log directories to remove (old standalone dir + new in-tree dir).
LOG_DIRS=("/var/log/observo" "$INSTALL_DIR/logs")
# Update staging dir (new layout only). Holds transient in-flight update
# artifacts (bundle, socket, flag file). Mirrors server.DefaultUpdateStagingDir.
UPDATE_DIR="$INSTALL_DIR/update"

# Single knob. Default (absent) removes EVERYTHING the agent installed
# (binaries, config, install dir, logs, update dir, and the observo user).
# When set, everything is still removed EXCEPT edge-config.json, which is
# left in place inside the install dir.
KEEP_CONFIG=false

usage() {
    echo "Usage: $0 [--keep-config]"
    echo "  --keep-config  Keep ONLY edge-config.json; remove everything else."
    echo "                 Without this flag, everything is removed."
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        --keep-config) KEEP_CONFIG=true ;;
        *) echo "Unknown argument: $arg"; usage ;;
    esac
done

OS="$(uname -s)"
echo "Uninstalling Observo Edge on $OS..."

kill_processes() {
    echo "Checking for running edge processes..."
    for name in "${PROCESS_NAMES[@]}"; do
        if pgrep -x "$name" > /dev/null 2>&1; then
            echo "Killing process: $name..."
            sudo pkill -x "$name" 2>/dev/null || true
            sleep 1
            if pgrep -x "$name" > /dev/null 2>&1; then
                echo "Force killing process: $name..."
                sudo pkill -9 -x "$name" 2>/dev/null || true
            fi
        fi
    done
}

# Step 1: Stop service / kill process
if [[ "$OS" == "Linux" ]]; then
    # Stop+disable+remove every known service variant (old and new).
    for svc in "${SERVICE_NAMES[@]}"; do
        svc_file="/etc/systemd/system/${svc}.service"
        if [[ -f "$svc_file" ]] || systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "${svc}.service"; then
            echo "Stopping systemd service: $svc..."
            sudo systemctl stop "$svc" 2>/dev/null || echo "Warning: failed to stop $svc (may not be running)."
            sudo systemctl disable "$svc" 2>/dev/null || echo "Warning: failed to disable $svc."
            if [[ -f "$svc_file" ]]; then
                echo "Removing service file: $svc_file..."
                sudo rm -f "$svc_file" || echo "Warning: failed to remove $svc_file."
            fi
        else
            echo "Service $svc not found, skipping."
        fi
    done
    # Update helper (non-root agent layout): path trigger, oneshot service,
    # the agent's shim drop-in, and the root-owned helper dir.
    sudo systemctl disable --now observo-edge-update.path 2>/dev/null || true
    sudo systemctl stop observo-edge-update.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/observo-edge-update.path /etc/systemd/system/observo-edge-update.service
    sudo rm -f /etc/systemd/system/observo-edge.service.d/10-update-shim.conf
    sudo rmdir /etc/systemd/system/observo-edge.service.d 2>/dev/null || true
    sudo rm -f /usr/local/libexec/observo/edge-watcher /usr/local/libexec/observo/systemd-run-noop
    sudo rmdir /usr/local/libexec/observo 2>/dev/null || true
    sudo systemctl daemon-reload 2>/dev/null || echo "Warning: failed to reload systemd daemon."

    # Also kill any stray processes left behind (e.g. an old nohup-launched edge).
    kill_processes

elif [[ "$OS" == "Darwin" ]]; then
    # New layout: unload + remove the launchd daemon(s).
    for label in "${LAUNCHD_LABELS[@]}"; do
        plist="/Library/LaunchDaemons/${label}.plist"
        echo "Unloading launchd service: $label..."
        sudo launchctl bootout "system/${label}" 2>/dev/null || true
        if [[ -f "$plist" ]]; then
            echo "Removing launchd plist: $plist..."
            sudo rm -f "$plist" || echo "Warning: failed to remove $plist."
        fi
    done

    # Old layout (and any leftovers): kill raw processes.
    kill_processes
else
    echo "Error: Unsupported OS: $OS"
    exit 1
fi

# Step 2: Remove binaries (old: edge + otelcontrib*; new: edge + edge-watcher + edge-worker)
if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Install directory $INSTALL_DIR not found, skipping binary removal."
else
    echo "Removing binaries from $INSTALL_DIR..."
    # Collect only binaries that actually exist. The fixed names (edge,
    # edge-watcher, edge-worker) have no glob chars so nullglob would NOT
    # drop them when missing; guard each with an explicit existence test.
    # otelcontrib* is a real glob (legacy collector) and nullglob applies.
    BINARIES=()
    for b in edge edge-watcher edge-worker; do
        [[ -e "$INSTALL_DIR/$b" ]] && BINARIES+=("$INSTALL_DIR/$b")
    done
    shopt -s nullglob
    BINARIES+=("$INSTALL_DIR"/otelcontrib*)
    shopt -u nullglob

    if [[ ${#BINARIES[@]} -eq 0 ]]; then
        echo "No binaries found in $INSTALL_DIR, skipping."
    else
        for f in "${BINARIES[@]}"; do
            echo "Removing $f..."
            sudo rm -f "$f" || echo "Warning: failed to remove $f."
        done
    fi

    # Remove runtime files left by the process (old + new, non-fatal if missing).
    for f in "$INSTALL_DIR/edge.pid" "$INSTALL_DIR/edge_output.log" "$INSTALL_DIR/output.log" "$INSTALL_DIR/effective.yaml"; do
        [[ -f "$f" ]] && sudo rm -f "$f"
    done
    # Sweep transient update artifacts (.bak rollback copies / .new staged
    # binaries) the watcher may have left in the install root (new layout).
    shopt -s nullglob
    for f in "$INSTALL_DIR"/*.bak "$INSTALL_DIR"/*.new; do
        sudo rm -f "$f"
    done
    shopt -u nullglob
fi

# Step 3: Remove config (kept only when --keep-config is set)
if [[ "$KEEP_CONFIG" == true ]]; then
    echo "Keeping config file (--keep-config set): $CONFIG_FILE"
else
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Config file $CONFIG_FILE not found, skipping."
    else
        echo "Removing config: $CONFIG_FILE..."
        sudo rm -f "$CONFIG_FILE" || echo "Warning: failed to remove $CONFIG_FILE."
    fi
fi

# The timestamped config history dir is not the config file, so it is always
# removed (even with --keep-config, which keeps only edge-config.json).
if [[ -d "$INSTALL_DIR/history" ]]; then
    echo "Removing config history: $INSTALL_DIR/history..."
    sudo rm -rf "$INSTALL_DIR/history" || echo "Warning: failed to remove $INSTALL_DIR/history."
fi

# Step 4: Remove install directory.
# When --keep-config is set we preserve the directory because edge-config.json
# lives inside it; every other entry (binaries, logs, update dir, history) is
# removed by the other always-run steps, leaving only edge-config.json behind.
# Otherwise we remove the whole dir.
if [[ "$KEEP_CONFIG" == true ]]; then
    echo "Preserving install directory (only $CONFIG_FILE retained): $INSTALL_DIR"
else
    if [[ ! -d "$INSTALL_DIR" ]]; then
        echo "Install directory $INSTALL_DIR not found, skipping."
    else
        echo "Removing install directory: $INSTALL_DIR..."
        sudo rm -rf "$INSTALL_DIR" || echo "Warning: failed to remove $INSTALL_DIR."
    fi
fi

# Step 5: Remove update staging directory (new layout only).
# Removed unconditionally (matches Windows uninstall) since it only holds
# transient artifacts; when the whole install dir was removed above this is
# already gone and we just skip.
if [[ -d "$UPDATE_DIR" ]]; then
    echo "Removing update staging directory: $UPDATE_DIR..."
    sudo rm -rf "$UPDATE_DIR" || echo "Warning: failed to remove $UPDATE_DIR."
fi

# Step 6: Remove log directories (old: /var/log/observo; new: $INSTALL_DIR/logs)
# Always removed (logs are never preserved).
for log_dir in "${LOG_DIRS[@]}"; do
    if [[ ! -d "$log_dir" ]]; then
        echo "Log directory $log_dir not found, skipping."
    else
        echo "Removing log directory: $log_dir..."
        sudo rm -rf "$log_dir" || echo "Warning: failed to remove $log_dir."
    fi
done

# Step 7: Remove system user and group (Linux only). Always removed.
if [[ "$OS" == "Linux" ]]; then
    if ! id "$OBSERVO_USER" &>/dev/null; then
        echo "User $OBSERVO_USER does not exist, skipping user removal."
    else
        echo "Removing system user: $OBSERVO_USER..."
        sudo userdel "$OBSERVO_USER" || echo "Warning: failed to remove user $OBSERVO_USER."
    fi

    # userdel may have already removed the primary group; only act if it still exists.
    if getent group "$OBSERVO_USER" > /dev/null 2>&1; then
        echo "Removing system group: $OBSERVO_USER..."
        sudo groupdel "$OBSERVO_USER" || echo "Warning: failed to remove group $OBSERVO_USER."
    fi
fi

echo "Observo Edge uninstalled successfully."
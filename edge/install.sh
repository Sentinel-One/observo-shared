#!/bin/bash

OBSERVO_HEADING="
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
                                                                                                                               
"


# sha1sum was only needed to derive a client-side AGENT_ID, which has been
# removed (identity is now server-assigned via enrollment). Dropped from prereqs.
PREREQS="sudo curl jq"

# -----------------------------------------------------------------------------
# Path resolution: env var > platform default. Every variable below is
# overridable via the corresponding environment variable so packagers can
# relocate binaries / config / logs without editing the script. If a value
# is unset we fall back to the same defaults the edge code uses
# (internal/server/constant_linux.go). LoadEdgeConfig will read these env
# vars on first boot and persist them into edge-config.json, keeping env /
# json / default in sync (bidirectional via WriteEdgeConfig).
# -----------------------------------------------------------------------------
# Single root directory for the whole edge install. All other paths
# are derived from this so an operator only needs to override one
# variable to relocate the install. Must mirror
# internal/server/constant_linux.go (RootDir).
ROOT_DIR="${ROOT_DIR:-${INSTALL_DIR:-/opt/observo}}"
INSTALL_DIR="$ROOT_DIR"
CONFIG_DIR="$ROOT_DIR"          # edge-config.json + effective.yaml live in the root
LOG_DIR="${LOG_DIR:-$ROOT_DIR/logs}"
# UPDATE_DIR is the on-disk staging area for in-flight updates and the
# heartbeat socket the watcher uses to coordinate with the supervisor.
# Must match server.DefaultUpdateStagingDir in
# internal/server/constant_linux.go ($ROOT_DIR/update).
UPDATE_DIR="${UPDATE_DIR:-$ROOT_DIR/update}"
# DATA_DIR is the dataplane (Vector) worker's persistent state directory
# (disk buffers, source checkpoints, validate_tmp). Must match
# server.DefaultWorkerDataDir in internal/server/constant_linux.go
# ($ROOT_DIR/data). Not created lazily by the worker -- must exist before
# validate/start or the worker fails with "data_dir ... does not exist".
DATA_DIR="${WORKER_DATA_DIR:-$ROOT_DIR/data}"
TMP_DIR="${TMP_DIR:-/tmp/observo}"
TAR_FILE="$TMP_DIR/edge.tar.gz"
EXTRACT_DIR="$TMP_DIR/binaries_edge"

# These env vars are read by the edge binary at boot. Binaries sit
# directly in ROOT_DIR; the worker collector log goes under logs/.
EDGE_EXECUTABLE="${EDGE_EXECUTABLE:-$ROOT_DIR/edge}"
WATCHER_EXECUTABLE="${WATCHER_EXECUTABLE:-$ROOT_DIR/edge-watcher}"
WORKER_EXECUTABLE_PATH="${WORKER_EXECUTABLE_PATH:-$ROOT_DIR/edge-worker}"
WORKER_CONFIG_PATH="${WORKER_CONFIG_PATH:-$ROOT_DIR/effective.yaml}"
WORKER_LOG_FILE_PATH="${WORKER_LOG_FILE_PATH:-$LOG_DIR/edge-worker.log}"
EDGE_CONFIG_PATH="${EDGE_CONFIG_PATH:-$ROOT_DIR/edge-config.json}"

CONFIG_FILE="$EDGE_CONFIG_PATH"
SERVICE_NAME="${SERVICE_NAME:-observo-edge}"
USER="${OBSERVO_USER:-observo}"

# Names of the three binaries we expect to find in the release bundle.
EDGE_BINARY_NAME="edge"
WATCHER_BINARY_NAME="edge-watcher"
WORKER_BINARY_NAME="edge-worker"

dependencies_check() {
    echo "Checking for script dependencies..."

    # Detect package manager
    if command -v apt &>/dev/null; then
        sudo apt-get update
        PKG_MANAGER="sudo apt-get install -y"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="sudo yum install -y"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="sudo dnf install -y"
    elif command -v brew &>/dev/null; then
        PKG_MANAGER="brew install"
    elif command -v apk &>/dev/null; then
        PKG_MANAGER="sudo apk add"
    else
        echo "Unsupported package manager. Install dependencies manually."
        exit 1
    fi

    # Check for missing dependencies
    for cmd in $PREREQS; do
        if ! command -v $cmd &>/dev/null; then
            echo "$cmd is missing. Installing..."
            $PKG_MANAGER $cmd || { echo "Failed to install $cmd"; exit 1; }
        else
            echo "$cmd is already installed."
        fi
    done
}

parse_environment_variable() {
    local env_var=""  # Make env_var local to the function
    while getopts "e:" opt; do
        case "$opt" in
            e) env_var="$OPTARG";;
            *) echo "Usage: $0 -e 'install_id=<JWT Token>'"; return 1;; # Return error code
        esac
    done

    # Reset OPTIND to 1.  This is CRUCIAL!
    OPTIND=1

    if [[ -z "$env_var" ]]; then
        echo "Error: Missing -e argument"
        return 1 # Return error code
    fi

    echo "Received environment variable: $env_var"

    # Correct the regular expression to capture only the value after install_id=
    if [[ "$env_var" =~ install_id=([A-Za-z0-9+/=]+) ]]; then
        TOKEN="${BASH_REMATCH[1]}"  # Extract the base64-encoded token value
        echo "Extracted install_id (base64): $TOKEN"

        # Decode the base64 string
        DECODED=$(echo "$TOKEN" | base64 --decode)
        echo "Decoded install_id (JSON): $DECODED"

        export TOKEN # Make TOKEN available to other functions. Crucial!
    else
        echo "Error: install_id not found in argument"
        return 1 # Failure
    fi

    # Correct the regular expression to capture only the value after download_url=
    if [[ "$env_var" =~ download_url=([^\ ]+) ]]; then
        DOWNLOAD_URL="${BASH_REMATCH[1]}"  # Extract the full presigned URL
        echo "Extracted download_url: $DOWNLOAD_URL"

        export DOWNLOAD_URL  # Make it available to other functions
    else
        echo "Error: download_url not found in argument"
        return 1  # Failure
    fi

    # checksum=<base64-sha256> is the SHA256 of the release tarball,
    # read directly from the S3 object's ChecksumSHA256 attribute by
    # fleet-manager. S3 returns this as base64 (NOT hex), so we keep
    # it in that form end-to-end and compare via
    # `openssl dgst -sha256 -binary FILE | base64`. We verify the
    # downloaded tarball against it BEFORE extracting (see
    # download_and_extract_agent). Mandatory: an install without
    # verification is a supply-chain hole.
    if [[ "$env_var" =~ checksum=([A-Za-z0-9+/=]+) ]]; then
        EXPECTED_CHECKSUM="${BASH_REMATCH[1]}"
        echo "Extracted checksum: $EXPECTED_CHECKSUM"
        export EXPECTED_CHECKSUM
    else
        echo "Error: checksum not found in argument"
        return 1
    fi

    return 0 # Success
}

detect_system() {
    OS="$(uname -s)"
    case "${OS}" in
        Linux*)     OS=linux;;
        Darwin*)    OS=darwin;;
        CYGWIN*|MINGW*|MSYS*) OS=windows;;
        *)          OS=unknown;;
    esac

    ARCH="$(uname -m)"
    case "${ARCH}" in
        x86_64)    ARCH=amd64;;
        arm64|aarch64)   ARCH=arm64;;
        armv7l)    ARCH=armv7;;
        i386|i686) ARCH=386;;
        *)         ARCH=unknown;;
    esac

    echo "Detected OS: $OS"
    echo "Detected Architecture: $ARCH"

    if [[ "$OS" == "unknown" || "$ARCH" == "unknown" ]]; then
        echo "Unsupported OS or architecture."
        exit 1
    fi
}

decode_and_extract_config() {
    echo "token $TOKEN"
    # Handle padding
    PADDING=$(( 4 - (${#TOKEN} % 4) ))
    if [[ $PADDING -gt 0 ]]; then
        TOKEN+=$(printf '=' %.s "" $(seq 1 $PADDING))
    fi

    # TODO CHECK THIS
    PAYLOAD=$(echo "$TOKEN" | base64 -d)

    SITE_ID=$(echo "$PAYLOAD" | jq -r '.site_id')
    AUTH_TOKEN=$(echo "$PAYLOAD" | jq -r '.auth_token')
    AGENT_VERSION=$(echo "$PAYLOAD" | jq -r '.agent_version')
    CONFIG_VERSION_ID=$(echo "$PAYLOAD" | jq -r '.config_version_id')
    FLEET_ID=$(echo "$PAYLOAD" | jq -r '.fleet_id')
    PLATFORM=$(echo "$PAYLOAD" | jq -r '.platform')
    EDGE_MANAGER_URL=$(echo "$PAYLOAD" | jq -r '.edge_manager_url')

    # edge_manager_tls_enabled is derived from the URL scheme rather than
    # trusted from the payload: the enrollment HTTP client (EnsureEnrolled ->
    # enrollEndpoint) reads this flag to decide http:// vs https://, with no
    # fallback/retry if it guesses wrong (unlike the OpAMP client's
    # schemeFlip). A wss:// (or https://) edge_manager_url with this flag
    # left false/unset makes enrollment fail permanently against a TLS-only
    # ingress -- fatal after 10 attempts, then crash-loop under systemd.
    case "$EDGE_MANAGER_URL" in
        wss://*|https://*) EDGE_MANAGER_TLS_ENABLED=true ;;
        *)                 EDGE_MANAGER_TLS_ENABLED=false ;;
    esac
    PAYLOAD=$(echo "$PAYLOAD" | jq --argjson tls "$EDGE_MANAGER_TLS_ENABLED" '. + {edge_manager_tls_enabled: $tls}')

    mkdir -p "$CONFIG_DIR"
    echo "$PAYLOAD" > "$CONFIG_FILE" # Directly write payload to file

    echo "SITE_ID: $SITE_ID"
    echo "AUTH_TOKEN: $AUTH_TOKEN"
    echo "AGENT_VERSION: $AGENT_VERSION"
    echo "CONFIG_VERSION_ID: $CONFIG_VERSION_ID"
    echo "FLEET_ID: $FLEET_ID"
    echo "PLATFORM: $PLATFORM"
    echo "EDGE_MANAGER_URL: $EDGE_MANAGER_URL"

    # SECURITY: the agent no longer self-generates AGENT_ID from machine-id /
    # hostname. A client-chosen UID is self-asserted identity — any host could
    # claim (or collide with) another agent's id. Identity is now assigned by
    # the server: on first boot the edge performs an enrollment exchange
    # (/enroll) and persists the server-assigned instance_uid + per-agent token
    # to edge-config.json. Do NOT reintroduce AGENT_ID generation here.
}


download_and_extract_agent() {
    PACKAGE="${PACKAGE_NAME}_${VERSION}_${OS}_${ARCH}.tar.gz"

    #TODO: remove this and point to our repo
    # DOWNLOAD_URL="${BASE_URL}/v${VERSION}/${PACKAGE}"
    echo "Downloading from $DOWNLOAD_URL"

    # Check if the URL is accessible (presigned URL might be expired)
    #if ! curl -s -L -I "$DOWNLOAD_URL" | grep -q "^HTTP/[12] 2"; then
    #    echo "Error: Download URL is not accessible. URL may have expired."
    #    exit 1
    #fi

    mkdir -p "$TMP_DIR"
    curl -L -# "$DOWNLOAD_URL" -o "$TAR_FILE"

    if [[ ! -f "$TAR_FILE" ]]; then
        echo "Error: Downloaded file not found at $TAR_FILE. URL may have expired or download failed."
        exit 1
    fi
    
    # if the url is expired then it make smaller file size. Check if file size is suspiciously small (likely an error response)
    FILE_SIZE=$(stat -f%z "$TAR_FILE" 2>/dev/null || stat -c%s "$TAR_FILE" 2>/dev/null || echo "0")
    MIN_EXPECTED_SIZE=10240  # 10KB minimum for a valid tar.gz archive
    
    if [[ $FILE_SIZE -lt $MIN_EXPECTED_SIZE ]]; then
        echo "Error: Downloaded file is too small ($FILE_SIZE bytes). Expected at least $MIN_EXPECTED_SIZE bytes."
        echo "This usually means the download URL has expired or returned an error response."
        echo "File contents (first 200 chars):"
        head -c 200 "$TAR_FILE" 2>/dev/null || cat "$TAR_FILE" | head -c 200
        echo ""
        exit 1
    fi
    
    echo "Download completed and saved to $TAR_FILE (size: $FILE_SIZE bytes)"

    # Verify the downloaded tarball's SHA256 matches the value
    # fleet-manager pulled from S3 (ChecksumSHA256, base64-encoded).
    # We compute the same way the update watcher does so the two
    # always agree: raw SHA256 → base64. Fail closed on mismatch —
    # do NOT proceed to extract a binary we can't verify.
    if command -v openssl >/dev/null 2>&1; then
        ACTUAL_CHECKSUM=$(openssl dgst -sha256 -binary "$TAR_FILE" | openssl base64 -A)
    elif command -v sha256sum >/dev/null 2>&1; then
        # Fallback: sha256sum emits hex, convert to base64.
        ACTUAL_CHECKSUM=$(sha256sum "$TAR_FILE" | awk '{print $1}' | xxd -r -p | base64)
    else
        echo "Error: neither openssl nor sha256sum is installed; cannot verify download integrity"
        exit 1
    fi
    if [[ "$ACTUAL_CHECKSUM" != "$EXPECTED_CHECKSUM" ]]; then
        echo "Error: checksum mismatch for $TAR_FILE"
        echo "  expected (from S3): $EXPECTED_CHECKSUM"
        echo "  actual (computed):  $ACTUAL_CHECKSUM"
        echo "Refusing to install a tampered or corrupted binary."
        exit 1
    fi
    echo "Checksum verified: $ACTUAL_CHECKSUM"

    mkdir -p "$EXTRACT_DIR"
    echo "Extracting $TAR_FILE to $EXTRACT_DIR"
    tar -xzvf "$TAR_FILE" -C "$EXTRACT_DIR" || { echo "Extraction failed!"; exit 1; }
    echo "Extraction complete. Files are in $EXTRACT_DIR"
}

move_to_bin_and_make_executable() {
    # The release bundle is expected to contain exactly three binaries,
    # named `edge`, `edge-watcher`, and `edge-worker`. They are installed
    # to the paths resolved earlier from env vars (or defaults), so an
    # operator who sets, say, WORKER_EXECUTABLE_PATH=/usr/local/bin/ew
    # gets the worker dropped there and the edge will then find it via
    # the same env var on boot.
    install_binary() {
        local src_name="$1"
        local dest_path="$2"

        local src
        src=$(find "$EXTRACT_DIR" -type f -name "$src_name" | head -n 1)
        if [[ -z "$src" ]]; then
            echo "Error: $src_name not found in bundle at $EXTRACT_DIR"
            exit 1
        fi
        sudo mkdir -p "$(dirname "$dest_path")"
        echo "Installing $src -> $dest_path"
        sudo mv "$src" "$dest_path" || { echo "Move failed for $src_name"; exit 1; }
        # All three binaries (edge, edge-watcher, edge-worker) must end
        # up with identical ownership and exec permissions. The
        # supervisor fork/execs the watcher under the same UID it runs
        # under (the systemd User= below), so any mismatch surfaces as
        # `fork/exec ... operation not permitted` at update time. Set
        # mode + ownership explicitly here per file rather than
        # relying solely on the directory-wide chown later, so even if
        # the bundle's tar entries carried stray uid/mode bits we
        # normalise them.
        sudo chown "$USER:$USER" "$dest_path"
        sudo chmod 0755 "$dest_path"
    }

    install_binary "$EDGE_BINARY_NAME"    "$EDGE_EXECUTABLE"
    install_binary "$WATCHER_BINARY_NAME" "$WATCHER_EXECUTABLE"
    install_binary "$WORKER_BINARY_NAME"  "$WORKER_EXECUTABLE_PATH"

    # Belt-and-suspenders: recursively normalise the entire install
    # directory in case any sibling files (config, certs, staging
    # area) were created with different ownership.
    # Since edge runs as root, set ownership to root:root for consistency.
    echo "Setting ownership of $INSTALL_DIR to root:root"
    sudo chown -R root:root "$INSTALL_DIR"

    # Ensure proper permissions for the directory and config file
    sudo chmod 755 "$INSTALL_DIR"
    if [[ -f "$CONFIG_FILE" ]]; then
        sudo chmod 644 "$CONFIG_FILE"
    fi

    # Sanity check: confirm each binary is owned by root and is executable.
    # Catching this here is much friendlier than the later "fork/exec ...: operation not permitted"
    # failure the supervisor would log mid-update.
    for bin in "$EDGE_EXECUTABLE" "$WATCHER_EXECUTABLE" "$WORKER_EXECUTABLE_PATH"; do
        if [[ ! -x "$bin" ]]; then
            echo "Error: $bin is not executable after install" >&2
            exit 1
        fi
        local owner
        owner=$(stat -c '%U:%G' "$bin" 2>/dev/null || stat -f '%Su:%Sg' "$bin" 2>/dev/null)
        if [[ "$owner" != "root:root" ]]; then
            echo "Error: $bin has owner $owner after install (expected root:root)" >&2
            exit 1
        fi
    done

    echo "deleting $EXTRACT_DIR"
    rm -rf $EXTRACT_DIR
    rm -rf $TMP_DIR
}

start_server() {
    echo "starting server"
    EDGE_BINARY_FILE=$(find "$INSTALL_DIR" -type f -executable -name "edge" | head -n 1)
    echo "$EDGE_BINARY_FILE"

    if [[ -z "$EDGE_BINARY_FILE" ]]; then
        echo "Error: No executable file found in $INSTALL_DIR!"
        exit 1
    fi
    echo "nohup $EDGE_BINARY_FILE > $INSTALL_DIR/output.log 2>&1 &"
    nohup "$EDGE_BINARY_FILE" > "$INSTALL_DIR/edge_output.log" 2>&1 &
    echo $! > "$INSTALL_DIR/edge.pid"
    echo "Observo Edge started with PID $(cat "$INSTALL_DIR/edge.pid")"
}

create_system_user() {
    echo "Creating system user and group: $USER"
    unameOut="$(uname -s)"
    case "${unameOut}" in
        Linux*)
	    echo "Linux"
            if command -v useradd &>/dev/null; then
                if ! getent group "$USER" > /dev/null; then
                    echo "Creating group '$USER'..."
                    groupadd --system "$USER" || echo "Group creation failed"
                fi

                if ! id "$USER" &>/dev/null; then
                    echo "Creating system user '$USER'..."
                    useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$USER" "$USER" || echo "User creation failed"
                fi

            elif command -v adduser &>/dev/null; then
                if ! getent group "$USER" > /dev/null; then
                    sudo addgroup -S "$USER"
                fi

                if ! id "$USER" &>/dev/null; then
                    adduser -S -H -s /sbin/nologin -G "$USER" "$USER"
                fi
            fi
            ;;
        Darwin*)
            echo "macOS detected. Please create user manually or handle via launchd if needed."
            ;;
        CYGWIN*|MINGW*|MSYS*)
            echo "Windows detected. User creation not supported in this script."
            ;;
        *)
            echo "Unsupported OS. Please create user manually."
            exit 1
            ;;
    esac
}

setup_directories() {
    # Lay down the canonical directory tree:
    #   $ROOT_DIR/                  binaries + edge-config.json + effective.yaml
    #   $ROOT_DIR/logs/             edge-worker, supervisor, update-watcher logs
    #   $ROOT_DIR/update/           staging dir + heartbeat socket + flag file
    #   $ROOT_DIR/data/             dataplane (Vector) worker persistent state
    # Single chown -R later normalises ownership across the whole tree.
    echo "Setting up edge directory tree under $ROOT_DIR"
    for d in "$ROOT_DIR" "$LOG_DIR" "$UPDATE_DIR" "$DATA_DIR"; do
        if [ ! -d "$d" ]; then
            echo "  creating $d"
            sudo mkdir -p "$d" || { echo "Failed to create $d"; exit 1; }
        fi
    done

    echo "Setting ownership to root:root (edge runs as root)"
    sudo chown root:root "$ROOT_DIR" "$LOG_DIR" "$UPDATE_DIR" "$DATA_DIR" \
        || { echo "Failed to set ownership on edge directories"; exit 1; }
    sudo chmod 0755 "$ROOT_DIR" "$LOG_DIR" "$UPDATE_DIR" "$DATA_DIR"
}

create_systemd_service() {
    echo "Setting up systemd service for Observo Edge..."

    unameOut="$(uname -s)"
    if [[ "$unameOut" != "Linux" ]]; then
        echo "Systemd setup is only supported on Linux. Detected OS: $(uname -s)"
        return
    fi

    if [[ ! -f "$EDGE_EXECUTABLE" ]]; then
        echo "Error: edge binary missing at $EDGE_EXECUTABLE"
        exit 1
    fi
    if [[ ! -f "$WATCHER_EXECUTABLE" ]]; then
        echo "Error: watcher binary missing at $WATCHER_EXECUTABLE"
        exit 1
    fi
    if [[ ! -f "$WORKER_EXECUTABLE_PATH" ]]; then
        echo "Error: worker binary missing at $WORKER_EXECUTABLE_PATH"
        exit 1
    fi

    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    echo "Creating systemd service file: $SERVICE_FILE"
    # Env vars below are the contract between the installer and the
    # edge binary's LoadEdgeConfig: on boot, LoadEdgeConfig reads them
    # (env > json > default) and writes them back into edge-config.json
    # so subsequent restarts see the same layout even if the unit file
    # is later edited. Keep the list aligned with
    # internal/server/constant.go.
    tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Observo Agent Service
After=network.target

[Service]
Type=simple
ExecStart=$EDGE_EXECUTABLE
Restart=always
RestartSec=5
# NOTE: edge runs as root so the update watcher (spawned by edge) inherits
# root privileges and can call systemctl restart/stop directly without sudo.
# Running as root also avoids permission issues with /opt/observo files.
User=root
Group=root
WorkingDirectory=$INSTALL_DIR

# NOTE: AGENT_ID is intentionally NOT set here. The edge obtains its
# server-assigned identity via enrollment on first boot and persists it to
# edge-config.json; injecting a client-side AGENT_ID would reintroduce the
# self-asserted-identity risk.
Environment="SITE_ID=$SITE_ID"
Environment="AUTH_TOKEN=$AUTH_TOKEN"
Environment="AGENT_VERSION=$AGENT_VERSION"
Environment="CONFIG_VERSION_ID=$CONFIG_VERSION_ID"
Environment="FLEET_ID=$FLEET_ID"
Environment="PLATFORM=$PLATFORM"
Environment="EDGE_MANAGER_URL=$EDGE_MANAGER_URL"
Environment="EDGE_CONFIG_PATH=$EDGE_CONFIG_PATH"
Environment="EDGE_EXECUTABLE=$EDGE_EXECUTABLE"
Environment="WATCHER_EXECUTABLE=$WATCHER_EXECUTABLE"
Environment="WORKER_EXECUTABLE_PATH=$WORKER_EXECUTABLE_PATH"
Environment="WORKER_CONFIG_PATH=$WORKER_CONFIG_PATH"
Environment="WORKER_LOG_FILE_PATH=$WORKER_LOG_FILE_PATH"
Environment="WORKER_DATA_DIR=$DATA_DIR"

# All edge-related logs live under $LOG_DIR (= $ROOT_DIR/logs by default).
StandardOutput=append:$LOG_DIR/observo-edge.log
StandardError=append:$LOG_DIR/observo-edge.log

[Install]
WantedBy=multi-user.target
EOF
    echo "Reloading systemd daemon..."
    sudo systemctl daemon-reexec || echo "daemon-reexec failed"
    sudo systemctl daemon-reload || echo "daemon-reload failed"

    echo "Enabling and starting $SERVICE_NAME..."
    sudo systemctl enable "$SERVICE_NAME" || echo "Enable failed"
    sudo systemctl restart "$SERVICE_NAME" || echo "Restart failed"
}

echo "$OBSERVO_HEADING"

#1 create user and group
create_system_user

#2 setup root + logs + update directory tree
setup_directories

#3 check and parse environment variable
if ! parse_environment_variable "$@"; then exit 1; fi # Check if parsing was successful.

#4. check for dependencies needed are present. install if missing
dependencies_check

#5. identify arch
detect_system

#6. decode and extract config from base64 encoded token.
#   store  the config at $CONFIG_FILE location
decode_and_extract_config

#7. construct the download url required for the system and download the tar
#   extract binary at $TMP_DIR
download_and_extract_agent

#8. move the binary to $INSTALL_DIR and give execution permissions
move_to_bin_and_make_executable

#9 create systemd service
create_systemd_service
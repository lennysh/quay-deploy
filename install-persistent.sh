#!/bin/bash
#
# This script installs and enables a persistent, rootless Quay registry
# using systemd Quadlet files and STATIC IPs.
#
# This version fixes all known .env and systemd path issues.
#

# --- Script Setup ---
set -e
set -u
set -o pipefail

# --- Source Configuration ---
# Find the directory where this script is located
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
ENV_FILE="$SCRIPT_DIR/quay.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ FATAL: Configuration file not found at: $ENV_FILE" >&2
    echo "Please create quay.env in the same directory as this script." >&2
    exit 1
fi

info "Checking quay.env for unquoted passwords..."
if grep -E '^(POSTGRES_PASSWORD|REDIS_PASS)=' "$ENV_FILE" | grep -v -E "='.*'" &> /dev/null; then
    echo "❌ FATAL: Unquoted password found in $ENV_FILE." >&2
    echo "Please edit your $ENV_FILE and wrap your POSTGRES_PASSWORD and REDIS_PASS in SINGLE QUOTES." >&2
    echo "Example: POSTGRES_PASSWORD='your!pass@word'" >&2
    exit 1
fi
info "Password check passed."

# Clean the file of invisible Windows characters, if possible
if command -v dos2unix &> /dev/null; then
    info "Cleaning $ENV_FILE of any invisible characters..."
    dos2unix "$ENV_FILE" >/dev/null 2>&1
fi

# We can now safely source the file
info "Loading configuration from $ENV_FILE..."
source "$ENV_FILE"

# --- Verify Variables (this time it will work) ---
info "Checking loaded variables..."
: "${POSTGRES_DB:?FATAL: POSTGRES_DB is not set or empty in $ENV_FILE}"
: "${POSTGRES_USER:?FATAL: POSTGRES_USER is not set or empty in $ENV_FILE}"
: "${POSTGRES_PASSWORD:?FATAL: POSTGRES_PASSWORD is not set or empty in $ENV_FILE}"
: "${PG_VERSION:?FATAL: PG_VERSION is not set or empty in $ENV_FILE}"
: "${REDIS_PASS:?FATAL: REDIS_PASS is not set or empty in $ENV_FILE}"
: "${QUAY_NET:?FATAL: QUAY_NET is not set or empty in $ENV_FILE}"
: "${QUAY_NET_SUBNET:?FATAL: QUAY_NET_SUBNET is not set or empty in $ENV_FILE}"
: "${PG_IP:?FATAL: PG_IP is not set or empty in $ENV_FILE}"
: "${REDIS_IP:?FATAL: REDIS_IP is not set or empty in $ENV_FILE}"
: "${QUAY:?FATAL: QUAY is not set or empty in $ENV_FILE}"
info "All variables loaded successfully."

# Get absolute path for systemd
ABS_QUAY_DIR=$(readlink -f "$QUAY")
# --- End Config Parsing ---


# --- Prerequisites Check ---
check_deps() {
    info "Checking dependencies..."
    command -v podman >/dev/null 2>&1 || fatal "podman is not installed. Please install it to continue."
    command -v sed >/dev/null 2>&1 || fatal "sed is not installed. Please install it to continue."
    info "All dependencies found."
}

# --- Main ---
main() {
    check_deps

    # --- Part 1: Prepare Environment ---
    info "Creating Quay setup in: $QUAY"
    mkdir -p "$QUAY/postgres"
    mkdir -p "$QUAY/config"
    mkdir -p "$QUAY/storage"
    info "Created data and config directories."

    # Copy .env file to a permanent location
    PERMANENT_ENV_FILE="$QUAY/config/quay.env"
    info "Copying $ENV_FILE to permanent location at $PERMANENT_ENV_FILE..."
    cp "$ENV_FILE" "$PERMANENT_ENV_FILE"
    ABS_ENV_FILE=$(readlink -f "$PERMANENT_ENV_FILE") # Update variable to new path

    info "Ensuring podman network '$QUAY_NET' exists..."
    if ! podman network exists "$QUAY_NET"; then
        podman network create --subnet "$QUAY_NET_SUBNET" "$QUAY_NET"
        info "Network '$QUAY_NET' created with subnet $QUAY_NET_SUBNET."
    else
        info "Network '$QUAY_NET' already exists."
    fi

    # --- Part 2: Create Quadlet Files ---
    SERVICE_DIR="$HOME/.config/containers/systemd"
    info "Creating Quadlet directory at $SERVICE_DIR..."
    mkdir -p "$SERVICE_DIR"

    info "Generating Quadlet file: quay-postgres.container"
    cat << EOF > "$SERVICE_DIR/quay-postgres.container"
[Unit]
Description=Quay Postgresql Database
Wants=network-online.target
After=network-online.target

[Container]
Image=docker.io/library/postgres:$PG_VERSION
Network=$QUAY_NET
IP=$PG_IP
PublishPort=5432:5432
EnvironmentFile=$ABS_ENV_FILE
Volume=$ABS_QUAY_DIR/postgres:/var/lib/postgresql/data:Z

[Install]
WantedBy=default.target
EOF

    info "Generating Quadlet file: quay-redis.container"
    cat << EOF > "$SERVICE_DIR/quay-redis.container"
[Unit]
Description=Quay Redis Cache
Wants=network-online.target
After=network-online.target

[Container]
Image=docker.io/library/redis:5.0.7
Network=$QUAY_NET
IP=$REDIS_IP
PublishPort=6379:6379
EnvironmentFile=$ABS_ENV_FILE
Exec=redis-server --requirepass \${REDIS_PASS}

[Install]
WantedBy=default.target
EOF

    info "Reloading systemd user daemon..."
    systemctl --user daemon-reload
    sleep 2 # Give systemd a moment to process generators

    info "Starting persistent postgres and redis services..."
    systemctl --user start quay-postgres.service
    systemctl --user start quay-redis.service

    info "Waiting 15s for dependencies to initialize..."
    sleep 15
    
    info "PostgreSQL is running at (static) IP: $PG_IP"
    info "Redis is running at (static) IP: $REDIS_IP"


    # --- Part 3: Manual Configuration ---
    CONFIG_FILE_PATH="$QUAY/config/quay-config.tar.gz"

    echo
    echo "========================================================================"
    echo "     >>>>>>>>>   MANUAL ACTION REQUIRED   <<<<<<<<<"
    echo "========================================================================"
    echo
    echo "The persistent 'postgres' and 'redis' services are now running."
    echo "You must now generate the 'config.yaml' using the STATIC IPs."
    echo
    echo "1. Run the following command in a SEPARATE terminal:"
    echo
    echo "   podman run --rm -it --name quay_config --network $QUAY_NET -p 8080:8080 quay.io/projectquay/quay config secret"
    echo
    echo "2. Open http://localhost:8080 in your browser."
    echo "3. Log in with credentials: quayconfig / secret"
    echo "4. Click 'Start New Registry Setup' and use these exact values:"
    echo
    echo "   --- Database Setup (USE THESE STATIC IPs) ---"
    echo "   Database Type: Postgres"
    echo "   Host:      $PG_IP"
    echo "   User:      $POSTGRES_USER"
    echo "   Password:  $POSTGRES_PASSWORD"
    echo "   Database:  $POSTGRES_DB"
    echo "   (Click 'Validate Database Settings' and then 'Create Super User')"
    echo
    echo "   --- Main Config Screen (USE THESE STATIC IPs) ---"
    echo "   Server Hostname: localhost:8080"
    echo "   TLS:             None (Not for Production)"
    echo "   Redis Hostname:  $REDIS_IP"
    echo "   Redis Password:  $REDIS_PASS"
    echo
    echo "5. Click 'Save Configuration Changes' at the bottom."
    echo "6. On the next screen, click 'Download Configuration'."
    echo "7. Save the 'quay-config.tar.gz' file to this *exact* location:"
    echo "   $CONFIG_FILE_PATH"
    echo
    echo "8. After saving, stop the 'quay_config' container (CTRL-C) in the other terminal."
    echo

    read -p "Press [Enter] ONLY after you have saved the config file to the location above..."

    # --- Part 4: Unpack, PATCH, and Run Quay ---

    if [ ! -f "$CONFIG_FILE_PATH" ]; then
        fatal "Config file not found: $CONFIG_FILE_PATH. Please re-run the script and follow the instructions carefully."
    fi

    info "Unpacking configuration..."
    cd "$QUAY/config"
    tar xvf quay-config.tar.gz

    # Define all incompatible settings in an array.
    local patches_to_remove=(
        "keepalivescount"
        "keepalivesidle"
        "keepalivesinterval"
        "tcpusertimeout"
    )

    info "Applying patches to config.yaml..."
    if [ -f "config.yaml" ]; then
        local sed_expressions=()
        for patch in "${patches_to_remove[@]}"; do
            info "Queueing patch to remove incompatible setting: '${patch}'"
            sed_expressions+=("-e" "/${patch}/d")
        done
        sed -i "${sed_expressions[@]}" config.yaml
        info "Config patching complete."
    else
        fatal "config.yaml not found after unpacking. Cannot apply patch."
    fi

    cd - >/dev/null # Go back to previous dir silently
    info "Config unpacked and patched."

    # --- Part 5: Create and Start Main Quay Service ---
    info "Generating Quadlet file: quay-quay.container"
    cat << EOF > "$SERVICE_DIR/quay-quay.container"
[Unit]
Description=Quay Container Registry
Wants=network-online.target
After=network-online.target quay-postgres.service quay-redis.service
BindsTo=quay-postgres.service quay-redis.service

[Container]
Image=quay.io/projectquay/quay:latest
Network=$QUAY_NET
PublishPort=8080:8080
EnvironmentFile=$ABS_ENV_FILE
Volume=$ABS_QUAY_DIR/config:/conf/stack:Z
Volume=$ABS_QUAY_DIR/storage:/datastorage:Z
PodmanArgs=--privileged

[Install]
WantedBy=default.target
EOF

    info "Reloading systemd user daemon..."
    systemctl --user daemon-reload
    sleep 2

    info "Checking if generator created the service files..."
    if ! systemctl --user list-unit-files | grep -q "quay-quay.service"; then
        fatal "systemd generator FAILED to create quay-quay.service."
    fi
    info "Generator check passed. Service file 'quay-quay.service' was created."

    info "Starting 'quay-quay.service' now..."
    systemctl --user start quay-quay.service

    info "Enabling 'quay-quay.service' to start on boot..."
    systemctl --user enable quay-quay.service

    echo
    echo "========================================================================"
    echo "  🎉 SUCCESS: Persistence is enabled via Quadlets! 🎉"
    echo "========================================================================"
    echo
    echo "If you have not already, run this command ONCE to enable start at boot:"
    echo
    echo "   loginctl enable-linger $(whoami)"
    echo
    echo "Your 'start.sh' script is no longer needed. Use systemctl to manage your services:"
    echo "   systemctl --user status quay-quay.service"
    echo "   systemctl --user stop quay-quay.service"
    echo "   systemctl --user start quay-quay.service"
    echo
}

# Run the main function
main
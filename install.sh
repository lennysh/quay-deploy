#!/bin/bash
#
# This script automates the rootless setup of a local Quay registry on a
# podman host, using a dedicated podman network for communication.
#
# It will pause for a required manual step via the web config tool.
#
# It includes a patch to remove 'keepalivescount' from the config
# to fix incompatibility with modern Postgres.
#

# --- Script Setup ---
set -e
set -u
set -o pipefail

# --- Source Configuration ---
# Find the directory where this script is located
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
ENV_FILE="$SCRIPT_DIR/quay.env"

if [ -f "$ENV_FILE" ]; then
    # Sourcing the .env file to load variables
    source "$ENV_FILE"
else
    echo "❌ FATAL: Configuration file not found at: $ENV_FILE" >&2
    echo "Please create quay.env in the same directory as this script." >&2
    exit 1
fi

# --- Helper Functions ---
info() {
    echo "✅ INFO: $1"
}

fatal() {
    echo "❌ FATAL: $1" >&2
    exit 1
}

# --- Prerequisites Check ---
check_deps() {
    info "Checking dependencies..."
    command -v podman >/dev/null 2>&1 || fatal "podman is not installed. Please install it to continue."
    command -v sed >/dev/null 2>&1 || fatal "sed is not installed. Please install it to continue."
    info "All dependencies found."
}

# --- Main Setup ---
main() {
    check_deps

    info "Starting Quay setup in: $QUAY"
    mkdir -p "$QUAY/postgres"
    mkdir -p "$QUAY/config"
    mkdir -p "$QUAY/storage"
    info "Created data and config directories."

    # --- Part 1: Create Network & Start Dependencies ---
    info "Creating podman network '$QUAY_NET'..."
    if ! podman network exists "$QUAY_NET"; then
        podman network create "$QUAY_NET"
        info "Network created."
    else
        info "Network '$QUAY_NET' already exists."
    fi

    info "Starting PostgreSQL $PG_VERSION container on '$QUAY_NET'..."
    podman run -d --rm --name postgresql \
        --network "$QUAY_NET" \
        -e POSTGRES_USER=$PG_USER \
        -e POSTGRES_PASSWORD=$PG_PASS \
        -e POSTGRES_DB=$PG_DB \
        -p 5432:5432 \
        -v "$QUAY/postgres:/var/lib/postgresql/data:Z" \
        "docker.io/library/postgres:$PG_VERSION"

    info "Waiting 15s for PostgreSQL to initialize..."
    sleep 15
    
    # --- IP ADDRESS FIX ---
    PG_IP=$(podman inspect postgresql -f "{{.NetworkSettings.Networks.\"$QUAY_NET\".IPAddress}}")
    if [ -z "$PG_IP" ]; then
        fatal "Could not get PostgreSQL IP address on network $QUAY_NET."
    fi
    info "PostgreSQL is running at IP: $PG_IP"
    # --- END FIX ---


    info "Enabling 'pg_trgm' extension in PostgreSQL..."
    podman exec -it postgresql /bin/bash -c "echo \"CREATE EXTENSION IF NOT EXISTS pg_trgm\" | psql -d $PG_DB -U ${PG_USER}"

    info "Starting Redis container on '$QUAY_NET'..."
    podman run -d --rm --name redis \
        --network "$QUAY_NET" \
        -p 6379:6379 \
        "docker.io/library/redis:5.0.7" \
        redis-server --requirepass $REDIS_PASS

    info "Waiting 5s for Redis to initialize..."
    sleep 5
    
    # --- IP ADDRESS FIX ---
    REDIS_IP=$(podman inspect redis -f "{{.NetworkSettings.Networks.\"$QUAY_NET\".IPAddress}}")
    if [ -z "$REDIS_IP" ]; then
        fatal "Could not get Redis IP address on network $QUAY_NET."
    fi
    info "Redis is running at IP: $REDIS_IP"
    # --- END FIX ---


    # --- Part 2: Manual Configuration ---
    CONFIG_FILE_PATH="$QUAY/config/quay-config.tar.gz"

    echo
    echo "========================================================================"
    echo "     >>>>>>>>>   MANUAL ACTION REQUIRED   <<<<<<<<<"
    echo "========================================================================"
    echo
    echo "The script will now pause. You must complete the Quay setup via"
    echo "the web UI in a SEPARATE terminal."
    echo
    echo "1. Run the following command in another terminal:"
    echo
    echo "   podman run --rm -it --name quay_config --network $QUAY_NET -p 8080:8080 quay.io/projectquay/quay config secret"
    echo
    echo "2. Open http://localhost:8080 in your browser."
    echo "3. Log in with credentials: quayconfig / secret"
    echo "4. Click 'Start New Registry Setup' and use these exact values:"
    echo
    echo "   --- Database Setup (USE THESE IPs) ---"
    echo "   Database Type: Postgres"
    echo "   Host:      $PG_IP"
    echo "   User:      $PG_USER"
    echo "   Password:  $PG_PASS"
    echo "   Database:  $PG_DB"
    echo "   (Click 'Validate Database Settings' and then 'Create Super User')"
    echo
    echo "   --- Main Config Screen (USE THESE IPs) ---"
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

    # --- Part 3: Unpack, PATCH, and Run Quay ---

    if [ ! -f "$CONFIG_FILE_PATH" ]; then
        fatal "Config file not found: $CONFIG_FILE_PATH. Please re-run the script and follow the instructions carefully."
    fi

    info "Unpacking configuration..."
    cd "$QUAY/config"
    tar xvf quay-config.tar.gz

    # Define all incompatible settings in an array.
    # Add any new keywords to this array.
    local patches_to_remove=(
        "keepalivescount"
        "keepalivesidle"
        "keepalivesinterval"
        "tcpusertimeout"
    )

    info "Applying patches to config.yaml..."
    if [ -f "config.yaml" ]; then
        # Build an array of sed expressions
        local sed_expressions=()

        for patch in "${patches_to_remove[@]}"; do
            info "Queueing patch to remove incompatible setting: '${patch}'"
            # Add a sed expression to delete any line containing the patch keyword
            sed_expressions+=("-e" "/${patch}/d")
        done

        # Run sed a single time with all expressions
        # This is much more efficient than running sed multiple times.
        sed -i "${sed_expressions[@]}" config.yaml

        info "Config patching complete."
    else
        fatal "config.yaml not found after unpacking. Cannot apply patch."
    fi

    cd - >/dev/null # Go back to previous dir silently
    info "Config unpacked and patched."

    info "Starting the main Quay registry container..."
    podman run --rm -p 8080:8080 \
        --name=quay \
        --network "$QUAY_NET" \
        --privileged=true \
        -v "$QUAY/config:/conf/stack:Z" \
        -v "$QUAY/storage:/datastorage:Z" \
        -d quay.io/projectquay/quay:latest

    info "Waiting 10s for Quay to start..."
    sleep 10
    
    # --- Part 4: Success and Test Commands ---
    echo
    echo "========================================================================"
    echo "  🎉 SUCCESS: Quay is now running! 🎉"
    echo "========================================================================"
    echo
    echo "You can access it at http://localhost:8080"
    echo "To check its logs, run: podman logs -f quay"
    echo
    echo "To test your registry, run these commands (replace YOUR_USERNAME):"
    echo
    echo "   podman login --tls-verify=false localhost:8080"
    echo "   # (Use the superuser credentials you created in the web UI)"
    echo
    echo "   podman pull busybox"
    echo "   podman tag busybox localhost:8080/YOUR_USERNAME/busybox:latest"
    echo "   podman push --tls-verify=false localhost:8080/YOUR_USERNAME/busybox:latest"
    echo

    # --- Part 5: Cleanup Info ---
    echo "--- To Stop and Clean Up ---"
    echo "When you are finished, run these commands to stop containers and remove all data:"
    echo
    echo "   podman stop quay postgresql redis"
    echo "   podman network rm $QUAY_NET"
    echo "   echo \"WARNING: This next command will permanently delete all Quay data:\""
    echo "   echo \"rm -rf $QUAY\""
    echo
}

# Run the main function
main
#!/bin/bash
#
# This script STARTS an existing rootless Quay registry environment
# that was previously set up by the install script.
#
# It will fail if the configuration or database directories are missing.
# It uses --replace to automatically clean up old, stopped containers.
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
    info "Checking for podman..."
    command -v podman >/dev/null 2>&1 || fatal "podman is not installed. Please install it to continue."
}

check_setup() {
    info "Checking for existing Quay setup in: $QUAY"
    if [ ! -d "$QUAY/config" ] || [ ! -f "$QUAY/config/config.yaml" ]; then
        fatal "Quay config directory or 'config.yaml' not found. Please run the install script first."
    fi
    
    if [ ! -d "$QUAY/postgres" ]; then
        fatal "Quay postgres directory not found. Please run the install script first."
    fi
    
    if [ ! -d "$QUAY/storage" ]; then
        fatal "Quay storage directory not found. Please run the install script first."
    fi
    info "Existing setup found."
}

# --- Main Setup ---
main() {
    check_deps
    check_setup

    # --- Part 1: Ensure Network & Start Dependencies ---
    info "Checking for podman network '$QUAY_NET'..."
    if ! podman network exists "$QUAY_NET"; then
        podman network create "$QUAY_NET"
        info "Network created."
    else
        info "Network '$QUAY_NET' already exists."
    fi

    info "Starting PostgreSQL container..."
    podman run -d --name postgresql \
        --replace \
        --network "$QUAY_NET" \
        -e POSTGRES_USER=$PG_USER \
        -e POSTGRES_PASSWORD=$PG_PASS \
        -e POSTGRES_DB=$PG_DB \
        -p 5432:5432 \
        -v "$QUAY/postgres:/var/lib/postgresql/data:Z" \
        "postgres:$PG_VERSION"

    info "Starting Redis container..."
    podman run -d --name redis \
        --replace \
        --network "$QUAY_NET" \
        -p 6379:6379 \
        redis:5.0.7 \
        --requirepass $REDIS_PASS

    # --- Part 2: Wait for Dependencies (Health Checks) ---
    info "Waiting for PostgreSQL to be ready..."
    until podman exec postgresql psql -d $PG_DB -U $PG_USER -c '\q' > /dev/null 2>&1; do
        info "  ...waiting for postgres..."
        sleep 2
    done
    info "PostgreSQL is ready."

    info "Waiting for Redis to be ready..."
    until podman exec redis redis-cli -a $REDIS_PASS ping | grep -q "PONG"; do
        info "  ...waiting for redis..."
        sleep 2
    done
    info "Redis is ready."

    # --- Part 3: Start Quay ---
    info "Starting the main Quay registry container..."
    podman run -p 8080:8080 \
        --name=quay \
        --replace \
        --network "$QUAY_NET" \
        --privileged=true \
        -v "$QUAY/config:/conf/stack:Z" \
        -v "$QUAY/storage:/datastorage:Z" \
        -d quay.io/projectquay/quay:latest

    info "Waiting 10s for Quay to start..."
    sleep 10

    # --- Part 4: Success ---
    echo
    echo "========================================================================"
    echo "  🎉 SUCCESS: Quay environment is starting! 🎉"
    echo "========================================================================"
    echo
    echo "You can access it at http://localhost:8080"
    echo "To check its logs, run: podman logs -f quay"
    echo
    echo "To stop all containers, run:"
    echo "   podman stop quay postgresql redis"
    echo
}

# Run the main function
main
#!/bin/bash
#
# This script enables persistence (start on reboot) for the Quay containers
# by generating and enabling systemd Quadlet files.
#
# This script should only be run ONCE.
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
    # Get the absolute path to the env file for systemd
    ABS_ENV_FILE=$(readlink -f "$ENV_FILE")
    # Get the absolute path to the data directory for systemd
    ABS_QUAY_DIR=$(readlink -f "$QUAY")
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

# --- Main ---
SERVICE_DIR="$HOME/.config/containers/systemd"
info "Creating Quadlet directory at $SERVICE_DIR..."
mkdir -p "$SERVICE_DIR"

# --- Ensure the podman network exists (Good Practice) ---
info "Ensuring podman network '$QUAY_NET' exists..."
if ! podman network exists "$QUAY_NET"; then
    podman network create "$QUAY_NET"
    info "Network '$QUAY_NET' created."
else
    info "Network '$QUAY_NET' already exists."
fi

# --- Create quay-postgres.container ---
info "Generating Quadlet file: quay-postgres.container"
cat << EOF > "$SERVICE_DIR/quay-postgres.container"
[Unit]
Description=Quay Postgresql Database
Wants=network-online.target
After=network-online.target

[Container]
Image=postgres:$PG_VERSION
Network=podman:$QUAY_NET
PublishPort=5432:5432
EnvironmentFile=$ABS_ENV_FILE
Volume=$ABS_QUAY_DIR/postgres:/var/lib/postgresql/data:Z

[Install]
WantedBy=default.target
EOF

# --- Create quay-redis.container ---
info "Generating Quadlet file: quay-redis.container"
cat << EOF > "$SERVICE_DIR/quay-redis.container"
[Unit]
Description=Quay Redis Cache
Wants=network-online.target
After=network-online.target

[Container]
Image=redis:5.0.7
Network=podman:$QUAY_NET
PublishPort=6379:6379
EnvironmentFile=$ABS_ENV_FILE
Command=redis-server
Command=--requirepass
Command=\${REDIS_PASS}

[Install]
WantedBy=default.target
EOF

# --- Create quay-quay.container ---
info "Generating Quadlet file: quay-quay.container"
cat << EOF > "$SERVICE_DIR/quay-quay.container"
[Unit]
Description=Quay Container Registry
Wants=network-online.target
After=network-online.target quay-postgres.service quay-redis.service
BindsTo=quay-postgres.service quay-redis.service

[Container]
Image=quay.io/projectquay/quay:latest
Network=podman:$QUAY_NET
PublishPort=8080:8080
EnvironmentFile=$ABS_ENV_FILE
Volume=$ABS_QUAY_DIR/config:/conf/stack:Z
Volume=$ABS_QUAY_DIR/storage:/datastorage:Z
PodmanArgs=--privileged

[Install]
WantedBy=default.target
EOF

# --- Enable Services ---
info "Reloading systemd user daemon..."
systemctl --user daemon-reload
sleep 1 # Give systemd a moment to process generators

info "Checking if generator created the service file..."
if ! systemctl --user list-unit-files | grep -q "quay-quay.service"; then
    fatal "systemd generator FAILED to create quay-quay.service. Check 'journalctl --user -xe' for errors."
fi
info "Generator check passed. Service file 'quay-quay.service' was created."

info "Enabling 'quay-quay.service' to start on boot..."
systemctl --user enable quay-quay.service

info "Starting 'quay-quay.service' now..."
systemctl --user start quay-quay.service

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
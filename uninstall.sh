#!/bin/bash
#
# This script completely UNINSTALLS and DELETES the Quay deployment,
# including containers, systemd files, network, and all data.
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

# --- Main Uninstall ---
main() {
    info "Starting full uninstallation of Quay..."

    # --- Step 1: Stop and remove running containers ---
    # We use the 'systemd-' prefixed names we saw in 'podman ps'
    # We use 'podman stop' because 'systemctl --user' is not working
    info "Stopping any running systemd containers..."
    podman stop systemd-quay-quay systemd-quay-postgres systemd-quay-redis || true
    
    # The containers are auto-removed because the Quadlet files imply --rm
    info "Containers stopped."

    # --- Step 2: Remove Quadlet .container files ---
    SERVICE_DIR="$HOME/.config/containers/systemd"
    info "Removing Quadlet files from $SERVICE_DIR..."
    rm -f "$SERVICE_DIR/quay-quay.container"
    rm -f "$SERVICE_DIR/quay-postgres.container"
    rm -f "$SERVICE_DIR/quay-redis.container"
    info "Quadlet files removed."

    # --- Step 3: Reload systemd daemon ---
    # This may fail with 'No medium found', but that's okay.
    # We must try, so it unloads the services.
    info "Reloading systemd user daemon (this may fail, it is safe to ignore)..."
    systemctl --user daemon-reload || true
    info "Systemd reload attempted."

    # --- Step 4: Remove podman network ---
    info "Removing podman network '$QUAY_NET'..."
    podman network rm "$QUAY_NET" || true
    info "Network removed."

    # --- Step 5: Remove all data ---
    info "WARNING: This will permanently delete all Quay data, config, and storage."
    info "The directory to be deleted is: $QUAY"
    echo
    read -p "Press [Enter] to PERMANENTLY delete this directory (or Ctrl+C to cancel)..."
    
    rm -rf "$QUAY"
    info "All data deleted from $QUAY."
    
    echo
    echo "========================================================================"
    echo "  🎉 SUCCESS: Quay has been completely uninstalled. 🎉"
    echo "========================================================================"
}

# Run the main function
main